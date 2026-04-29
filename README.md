# Insight

> Decision Intelligence Platform

**Insight** is an extensible platform that collects operational data from across an organisation's toolchain, resolves all activity to unified person identities, and delivers actionable analytics for productivity improvement, bottleneck detection, process performance tracking, and team health reviews.

This repository is the **monorepo** for the Insight product. It contains:
- **`src/`** — source code for all platform components
- **`docs/`** — canonical product and technical specifications (specs, designs, ADRs)

<!-- toc -->

- [What Is Insight](#what-is-insight)
- [Architecture Overview](#architecture-overview)
  - [Components](#components)
  - [Bronze → Silver → Gold pipeline](#bronze--silver--gold-pipeline)
- [Repository Structure](#repository-structure)
  - [`src/`](#src)
  - [`docs/`](#docs)
  - [`inbox/`](#inbox)
  - [`cypilot/`](#cypilot)
- [Connector Coverage](#connector-coverage)
- [Key Concepts](#key-concepts)
- [Working with This Repo](#working-with-this-repo)
- [Working with `docs/`](#working-with-docs)
  - [Document types](#document-types)
  - [Contribution workflow](#contribution-workflow)
  - [Summary](#summary)

<!-- /toc -->

---

## What Is Insight

Insight collects events and metrics from the tools teams already use — version control, task trackers, communication platforms, AI coding assistants, HR systems, and more — and unifies them into a single, identity-resolved data model.

**Primary use cases:**

| Use Case | Description |
|----------|-------------|
| **Process performance** | Cycle time, PR throughput, deployment frequency, task flow |
| **Productivity analytics** | Developer output, AI tool adoption, collaboration patterns |
| **Bottleneck detection** | Where work gets stuck across the delivery pipeline |
| **Team health** | Meeting load, async/sync balance, focus time |
| **Performance review** | Individual and team contribution signals across tools |
| **AI adoption tracking** | Usage, model distribution, and ROI across AI tools |

Insight is **not** a replacement for source systems — it reads from them, resolves identities, and provides a governed analytics layer on top.

---

## Architecture Overview

The solution consists of five main components:

```
┌──────────────────────────────────────────────────────────────────┐
│                          Frontend (SPA)                          │
│  Dashboards · Analytics · AI adoption · PR metrics · Team healt  │
└────────────────────────────┬─────────────────────────────────────┘
                             │ REST API (auth + data)
┌────────────────────────────▼─────────────────────────────────────┐
│                    Backend (REST API Server)                     │
│        Authentication · Authorization · User Management          │
│                     Data Proxy to Database                       │
└────────────────────────────┬─────────────────────────────────────┘
                             │ query
┌────────────────────────────▼─────────────────────────────────────┐
│                    Database (Analytics Store)                    │
│             Bronze → Silver → Gold (identity-resolved)           │
└────────────────────────────▲─────────────────────────────────────┘
                             │ write
┌────────────────────────────┴─────────────────────────────────────┐
│              Connector Orchestration Layer                       │
│         Scheduling · Retry · State management · Monitorin        │
└────────────────────────────▲─────────────────────────────────────┘
                             │ collect
┌────────────────────────────┴─────────────────────────────────────┐
│                         Connectors                               │
│   Git · Task Tracking · Collaboration · AI Tools · HR · CRM ...  │
└──────────────────────────────────────────────────────────────────┘
```

### Components

| # | Component | Description |
|---|-----------|-------------|
| 1 | **Connectors** | Source-specific integrations that pull raw data from external tools (git, task trackers, AI tools, HR systems, etc.) and write it to Bronze tables in the analytics database. |
| 2 | **Connector Orchestration** | Scheduling, retry, state management, and monitoring layer that coordinates connector runs and ensures reliable data ingestion. |
| 3 | **Database** | Analytics store holding the Bronze → Silver → Gold pipeline. Bronze is raw source data; Silver unifies schemas and resolves identities; Gold contains aggregated business metrics. |
| 4 | **Backend** | REST API server providing authentication, authorization, user management, and data proxy services. Serves as the central authentication gateway and data access layer, integrating with enterprise SSO systems. |
| 5 | **Frontend** | Single-page application (SPA) providing engineering managers, team leads, and developers with analytics and visualizations of git activity, AI tool adoption, pull request metrics, and team productivity. |

### Bronze → Silver → Gold pipeline

- **Bronze** — Raw, source-faithful tables. Field names and types preserved from the API. One table per entity type per source.
- **Silver Step 1** — Source tables unified into common schemas (e.g. `collab_chat_activity` merges Slack + Zulip + M365 Teams).
- **Silver Step 2** — Identity resolution: `email` / `login` / `user_id` resolved to canonical `person_id` via the Identity Manager.
- **Gold** — Aggregated, business-level metrics (cycle time, throughput, adoption rates, etc.).

---

## Repository Structure

### Root scripts

```
./dev-up.sh               ← Create Kind cluster + deploy all services
./init.sh             ← Apply secrets + initialize ingestion stack
./dev-down.sh             ← Stop services (data preserved)
./cleanup.sh          ← Delete cluster and all data
k8s/kind-config.yaml  ← Kind cluster configuration
```

### `src/`

Source code for all platform components.

```
src/
├── ingestion/        ← Data pipeline (Airbyte + Argo + ClickHouse + dbt)
├── backend/          ← REST API server (Rust + cyberfabric-core)
└── frontend/         ← SPA deployment (Dockerfile + Helm; source in separate repo)
```

### `docs/`

Canonical product, domain, and component specifications. The single source of truth for everything architectural and technical.

```
docs/
├── components/                   ← per-component specifications
│   ├── connectors/               ← per-source connector specs (PRD + DESIGN + ADR)
│   │   ├── README.md             ← connector index + unified streams table
│   │   ├── git/                  ← GitHub, Bitbucket Server, GitLab
│   │   ├── task-tracking/        ← YouTrack, Jira
│   │   ├── collaboration/        ← Microsoft 365, Slack, Zoom, Zulip
│   │   ├── wiki/                 ← Confluence, Outline
│   │   ├── support/              ← Zendesk, Jira Service Management
│   │   ├── ai/                   ← Claude Admin, Claude Enterprise, Cursor, Windsurf, GitHub Copilot, JetBrains, OpenAI API, ChatGPT Team
│   │   ├── hr-directory/         ← BambooHR, Workday, LDAP / Active Directory
│   │   ├── crm/                  ← HubSpot, Salesforce
│   │   ├── ui-design/            ← Figma
│   │   └── testing/              ← Allure TestOps
│   │
│   ├── orchestrator/             ← connector orchestration layer specs
│   ├── backend/                  ← REST API server specs
│   └── frontend/                 ← SPA specs
│
├── domain/                       ← cross-cutting domain designs
│   ├── connector/                ← Connector Framework: generic architecture, automation
│   │   └── specs/DESIGN.md       │  boundary, BaseConnector, Unifier, onboarding
│   │                             │  (per-source details stay in components/connectors/)
│   └── identity-resolution/      ← Identity Resolution Service: person registry,
│       └── specs/DESIGN.md       │  alias store, Bootstrap Job, Golden Record,
│                                 │  match rules, org hierarchy, GDPR erasure
│
└── shared/                       ← shared API guidelines, status codes, versioning
    └── api-guideline/
```

**`docs/domain/` vs `docs/components/`:**

| Folder | Contains | When to look here |
|---|---|---|
| `docs/domain/` | Cross-cutting platform domains: concepts, algorithms, data models, and contracts that span multiple components | Understanding *how* identity resolution works, *what* the connector framework contract is, *why* the Medallion boundary is where it is |
| `docs/components/` | Per-component and per-connector specs: PRD (requirements), DESIGN (schemas, APIs, implementation details), ADR | Building, extending, or reviewing a specific connector, the backend, or the frontend |

### `inbox/`

Incoming documents pending triage and integration into `docs/`. Not yet canonical.

| Folder | Status | Intended destination |
|--------|--------|----------------------|
| `architecture/CONNECTORS_ARCHITECTURE.md` + `CONNECTOR_AUTOMATION.md` | **Synthesized** → `docs/domain/connector/specs/DESIGN.md` | Complete |
| `architecture/IDENTITY_RESOLUTION_V*.md` + `IDENTITY_RESOLUTION.md` | **Synthesized** → `docs/domain/identity-resolution/specs/DESIGN.md` | Complete |
| `architecture/PRODUCT_SPECIFICATION.md` | Draft | `docs/domain/` or root product spec |
| `architecture/permissions/` | Draft ADRs | `docs/components/backend/specs/ADR/` |
| `airbyte-declarative-standalone/` | **Migrated** | `docs/components/connectors/collaboration/m365/` |
| `stats/backend/` | Draft ADRs | `docs/components/backend/specs/ADR/` |
| `stats/frontend/` | Draft | `docs/components/frontend/specs/` |
| `streams/` | Draft schemas | `docs/components/connectors/` — per-source stream definitions |

### `cypilot/`

This repo uses [Cypilot](https://github.com/cyberfabric/cyber-pilot) — an AI agent framework for spec authoring, validation, and traceability. The `cypilot/` directory contains the project-specific configuration (artifact registry, rules, kit bindings). The engine itself lives in the upstream repo.

---

## Connector Coverage

| Domain | Sources | Silver Stream |
|--------|---------|---------------|
| Version Control | GitHub, Bitbucket Server, GitLab | `class_commits`, `class_pr_activity` |
| Task Tracking | YouTrack, Jira | `class_task_tracker` |
| Collaboration | M365, Slack, Zoom, Zulip | `class_communication_metrics`, `class_document_metrics` |
| Wiki | Confluence, Outline | `class_wiki_pages`, `class_wiki_activity` |
| Support | Zendesk, JSM | `class_support_activity` |
| AI Dev Tools | Cursor, Windsurf, Copilot, JetBrains | `class_ai_dev_usage` |
| AI Tools | Claude Admin, Claude Enterprise, OpenAI API, ChatGPT Team | `class_ai_api_usage`, `class_ai_tool_usage` |
| HR / Directory | BambooHR, Workday, LDAP | `class_people`, `class_org_units` |
| CRM | HubSpot, Salesforce | TBD |
| Design Tools | Figma | `class_design_activity` |
| Quality / Testing | Allure TestOps | TBD |

---

## Key Concepts

**Identity Resolution** — Every Bronze table carries a source-native user identifier (`email`, `login`, `uuid`, etc.). The Identity Manager resolves these to a stable `person_id` in Silver Step 2, enabling cross-source analytics (e.g. joining a developer's git activity with their task tracker throughput and AI tool usage).

**Connector spec** — Each connector defines its Bronze table schemas, identity fields, Silver/Gold target streams, and open questions. The `{source}.md` file is the full technical spec; `specs/PRD.md` captures the code-agnostic requirements.

**Extendability** — Adding a new data source means: (1) defining Bronze tables, (2) mapping identity fields, (3) routing to an existing or new Silver stream. The architecture is designed to accommodate new connectors without changes to existing pipelines.

---

## Quick Start

Everything runs in a local [Kind](https://kind.sigs.k8s.io/) (Kubernetes-in-Docker) cluster named `insight`.

### 1. Install prerequisites

```bash
brew install kind kubectl helm docker
```

For backend development (optional): `brew install rustup protobuf && rustup default stable`
For frontend development (optional): `nvm install 25`

### 2. Create cluster and deploy services

```bash
./dev-up.sh
```

This creates a Kind cluster, installs ingress-nginx, and deploys:
- Ingestion stack (Airbyte, Argo Workflows, ClickHouse)
- Backend API Gateway (Rust, auth disabled locally)
- Frontend SPA (nginx)

ClickHouse deployment will be skipped until its Secret exists (next step).

### 3. Create secrets

```bash
cd src/ingestion/secrets

# Infrastructure (required)
cp clickhouse.yaml.example clickhouse.yaml
# Edit clickhouse.yaml — set a password

# Connectors (one per source you want to sync)
cp connectors/m365.yaml.example connectors/m365.yaml
# Edit with real OAuth credentials — see each connector's README

cd ../../..
```

### 4. Initialize

```bash
./init.sh
```

This applies secrets to the cluster, deploys ClickHouse, creates databases, registers connectors in Airbyte, creates connections, and generates Argo workflow schedules.

### 5. Run a sync (optional)

```bash
cd src/ingestion
./run-sync.sh m365 example-tenant
```

### Services

| Service | URL | Notes |
|---------|-----|-------|
| Frontend | http://localhost:8000 | SPA via ingress |
| API Gateway | http://localhost:8000/api/v1 | Auth disabled locally |
| Airbyte | http://localhost:8001 | Port-forward |
| Argo UI | http://localhost:30500 | No auth locally |
| ClickHouse | http://localhost:30123 | HTTP interface |

### Lifecycle

| Command | Description |
|---------|-------------|
| `./dev-up.sh` | Create cluster + deploy everything (idempotent) |
| `./dev-up.sh ingestion` | Only Airbyte, Argo, ClickHouse |
| `./dev-up.sh app` | Only backend + frontend |
| `./init.sh` | Apply secrets + initialize ingestion stack |
| `./dev-down.sh` | Stop all services (data preserved) |
| `./cleanup.sh` | Delete cluster and all data |

### Image configuration

Service images are controlled via environment variables in `.env.<name>`:

| Variable | Default | Description |
|----------|---------|-------------|
| `IMAGE_REGISTRY` | _(empty)_ | Registry prefix, e.g. `ghcr.io/cyberfabric` |
| `IMAGE_TAG` | `local` | Default image tag for all services |
| `API_GATEWAY_IMAGE_TAG` | `$IMAGE_TAG` | Override tag for api-gateway |
| `ANALYTICS_API_IMAGE_TAG` | `$IMAGE_TAG` | Override tag for analytics-api |
| `IDENTITY_IMAGE_TAG` | `$IMAGE_TAG` | Override tag for identity-resolution |
| `TOOLBOX_IMAGE_TAG` | `$IMAGE_TAG` | Override tag for insight-toolbox |
| `IMAGE_PULL_POLICY` | `IfNotPresent` | Kubernetes pull policy |
| `BUILD_IMAGES` | `true` | Build images locally before deploy |
| `BUILD_AND_PUSH` | `false` | Push built images to registry |
| `IMAGE_PLATFORM` | _(empty)_ | Cross-build platform, e.g. `linux/amd64` |

To deploy a specific version instead of `latest`:

```bash
# In .env.virtuozzo (or any remote env file)
IMAGE_REGISTRY=ghcr.io/cyberfabric
IMAGE_TAG=2026.04.21.14.30-abc1234    # default for all services
BUILD_IMAGES=false
```

To pin individual services to different versions:

```bash
IMAGE_TAG=2026.04.21.14.30-abc1234
ANALYTICS_API_IMAGE_TAG=2026.04.20.09.15-def5678   # override just analytics-api
```

The Argo workflow templates (`dbt-run`, `ingestion-pipeline`) also accept a
`toolbox_image` parameter to override the toolbox image at submission time.

### CI/CD

GitHub Actions builds and pushes container images on every merge to `main`
(see `.github/workflows/build-images.yml`). Images are tagged as
`YYYY.MM.DD.HH.mm-<short-sha>` and `latest`.

| Image | Trigger path |
|-------|-------------|
| `insight-api-gateway` | `src/backend/**` |
| `insight-analytics-api` | `src/backend/**` |
| `insight-identity-resolution` | `src/backend/**` |
| `insight-toolbox` | `src/ingestion/**` |

To trigger a build manually: Actions → "Build & Push Container Images" → Run workflow.

### Running without Kubernetes

For fast iteration on individual components without K8s:

```bash
# Backend
cd src/backend
cargo run --bin insight-api-gateway -- run -c services/api-gateway/config/no-auth.yaml
# → http://localhost:8080/api/v1

# Frontend
cd ../insight-front    # or via symlink
npm install && npm run dev
# → http://localhost:5173
```

See [`src/backend/services/LOCAL_DEV.md`](src/backend/services/LOCAL_DEV.md) for more backend development options (OIDC, different cluster tools, etc.).

---

## Working with This Repo

- **Browse specs** — Start at [`docs/components/connectors/README.md`](docs/components/connectors/README.md) for the connector index, or [`docs/domain/`](docs/domain/) for cross-cutting platform concepts (identity resolution, connector framework).
- **Understand a domain** — Read the relevant `docs/domain/{domain}/specs/DESIGN.md` first. These documents describe the platform's core algorithms, data contracts, and architectural decisions that span multiple components.
- **Add a connector** — Follow the layout in any existing `docs/components/connectors/{domain}/{source}/` directory. Use `specs/PRD.md` for requirements and `specs/DESIGN.md` for table schemas and pipeline mappings.
- **Add source code** — Place code under `src/{component}/`. The structure mirrors `docs/components/` — `src/connectors/`, `src/backend/`, `src/frontend/`, `src/orchestrator/`.
- **Cypilot** — Run `cypilot on` in a supported AI agent to activate assisted spec authoring, validation, and traceability. Cypilot is sourced from [github.com/cyberfabric/cyber-pilot](https://github.com/cyberfabric/cyber-pilot).
- **Inbox** — Documents in `inbox/` are drafts awaiting review. Do not reference them as canonical sources.

---

## Working with `docs/`

The `docs/` folder is the single source of truth for all product specifications, architectural decisions, and technical designs. Every document here is considered canonical and must go through a review process before being merged.

`docs/` describes the **architecture and intent** of the platform. The corresponding implementation lives in `src/`. When adding or changing source code, the relevant spec in `docs/components/{component}/specs/DESIGN.md` should be updated in the same PR (or a follow-up ADR opened if it's a significant design change).

### Document types

Each component or connector has a `specs/` subdirectory with three document types:

| File | Purpose | Who writes it |
|------|---------|---------------|
| `specs/PRD.md` | Business and product requirements — actors, use cases, functional requirements, NFRs. **Code-agnostic**: no schemas, no implementation details. | Product / domain owners |
| `specs/DESIGN.md` | Technical design — Bronze table schemas, identity resolution mechanics, Silver/Gold pipeline mappings, data flow. | Engineering |
| `specs/ADR/` | Architecture Decision Records — individual decisions that affect the design. | Engineering |

### Contribution workflow

#### Adding or updating requirements (PRD)

Business requirements, use cases, actor definitions, and functional/non-functional requirements belong in `specs/PRD.md` of the relevant component or connector.

1. Create a branch.
2. Edit `specs/PRD.md` — add or update requirements. Keep it code-agnostic: describe **what** the system must do, not how.
3. Open a PR for review. Once approved, merge.

#### Updating the technical design (DESIGN)

`specs/DESIGN.md` is the authoritative technical specification for a component. It must reflect the current agreed-upon design at all times.

**Minor changes** (style fixes, formatting, clarifications, small field additions) can be committed directly to `specs/DESIGN.md` via a standard PR.

**Major changes** (data schema changes, new pipeline stages, significant architectural decisions, breaking changes to existing models) require an ADR first:

1. Create a new ADR in `specs/ADR/` describing the proposed change (context, options considered, decision, consequences).
2. Open a PR with the ADR only.
3. Once the ADR is approved and merged, update `specs/DESIGN.md` in a follow-up commit or PR to reflect the accepted decision.

This ensures every significant design change has a traceable decision record before the canonical design document is updated.

#### ADR naming convention

```
specs/ADR/NNN-short-description.md
```

Example: `specs/ADR/001-use-email-as-identity-key.md`

### Summary

```
Propose requirement change       →  edit PRD.md       →  PR  →  merge
Propose minor design change      →  edit DESIGN.md    →  PR  →  merge
Propose major design change      →  new ADR           →  PR  →  merge  →  update DESIGN.md
```

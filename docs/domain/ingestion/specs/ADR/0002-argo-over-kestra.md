---
status: accepted
date: 2026-03-26
---

# ADR-0002: Use Argo Workflows over Kestra for Pipeline Orchestration

**ID**: `cpt-insightspec-adr-argo-over-kestra`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Argo Workflows](#argo-workflows)
  - [Keep Kestra + accept PostgreSQL dependency](#keep-kestra--accept-postgresql-dependency)
  - [Prefect](#prefect)
  - [Temporal](#temporal)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

The ingestion layer initially chose Kestra as the workflow orchestrator (see ADR-0001). During implementation, Kestra's hard dependency on PostgreSQL for its repository and queue subsystems became a blocking issue. Kestra's SQL migrations are incompatible with MariaDB, and the project's database strategy limits persistent stores to ClickHouse (analytics) and MariaDB (application state). Adding PostgreSQL solely for orchestrator state contradicts the database minimization goal.

## Decision Drivers

* Database minimization — the project targets only ClickHouse + MariaDB; adding PostgreSQL for one component is undesirable
* Kestra's MariaDB incompatibility — SQL migrations fail on MariaDB, confirmed in Kestra issue tracker
* Kubernetes-native operations — Airbyte already runs in a Kind K8s cluster via abctl; co-locating the orchestrator in the same cluster simplifies networking and deployment
* No external state dependency — orchestrator state should not require a dedicated database
* YAML-based workflow definitions — same driver as ADR-0001; team prefers declarative YAML over Python DAGs
* Retain existing capabilities — scheduling, DAG dependencies, retry policies, observability

## Considered Options

1. **Argo Workflows**
2. **Keep Kestra + accept PostgreSQL dependency**
3. **Prefect**
4. **Temporal**

## Decision Outcome

Chosen option: **Argo Workflows**, because it stores all workflow state in Kubernetes etcd — no external database required. It is already deployed in the same Kind cluster as Airbyte, uses Kubernetes-native CRDs for workflow definitions (YAML), and provides DAG-based task orchestration with retry policies and scheduling via CronWorkflows.

### Consequences

* Good, because no PostgreSQL or any additional database dependency — state stored in K8s etcd
* Good, because Kubernetes-native — runs in the same Kind cluster as Airbyte, uses standard K8s primitives (namespaces, services, secrets)
* Good, because WorkflowTemplates are YAML — consistent with Airbyte manifests, Terraform HCL, and K8s manifests
* Good, because DAG support with explicit task dependencies (`depends` field)
* Good, because built-in retry policies per template (`retryStrategy`)
* Good, because CronWorkflows replace Kestra's schedule triggers
* Good, because Argo UI provides execution monitoring and log access (NodePort 30500)
* Good, because Helm-based installation — single `helm upgrade --install` command
* Bad, because Argo Workflows has a smaller community than Apache Airflow (though larger than Kestra)
* Bad, because no built-in Airbyte or dbt plugins — integration is via HTTP calls and container steps, requiring custom WorkflowTemplates
* Bad, because YAML verbosity — Argo CRD syntax is more verbose than Kestra's flow definitions
* Bad, because etcd storage has size limits — large-scale production deployments may need artifact storage (S3/GCS) for workflow outputs

### Confirmation

Confirmed when:

- `argo list -n argo` shows submitted workflows
- CronWorkflow `m365-sync` triggers on schedule and completes the sync→transform DAG
- No PostgreSQL pods exist in the cluster
- `kubectl get pods -n argo` shows Argo server and controller running

## Pros and Cons of the Options

### Argo Workflows

Argo Workflows is a Kubernetes-native workflow engine for orchestrating parallel jobs. Workflows are defined as Kubernetes CRDs in YAML. Licensed under Apache 2.0. Part of the CNCF graduated project ecosystem.

* Good, because state stored in K8s etcd — no external database
* Good, because CNCF graduated project — strong governance and long-term viability
* Good, because native K8s integration — pods, services, secrets, RBAC
* Good, because DAG and step-based workflow definitions
* Good, because built-in retry, timeout, and resource management
* Good, because Helm chart for easy installation
* Good, because active community with 14k+ GitHub stars
* Neutral, because requires learning Argo CRD syntax (but team already knows K8s YAML)
* Bad, because no built-in connectors for Airbyte or dbt — custom templates needed
* Bad, because more verbose YAML compared to Kestra's concise flow syntax

### Keep Kestra + accept PostgreSQL dependency

Continue with Kestra as originally decided in ADR-0001, adding PostgreSQL to the infrastructure.

* Good, because no migration effort — existing flows continue to work
* Good, because built-in Airbyte and dbt plugins
* Good, because simpler flow syntax
* Bad, because adds PostgreSQL as a third database — contradicts database minimization strategy
* Bad, because PostgreSQL requires its own backup, monitoring, and upgrade procedures
* Bad, because increases infrastructure complexity for a local development environment
* Bad, because Kestra runs outside the K8s cluster (Docker Compose) while Airbyte runs inside — networking asymmetry

### Prefect

* Good, because modern Python API and clean developer experience
* Good, because Prefect Cloud provides managed hosting
* Bad, because Python-centric — same constraint as Airflow for this team
* Bad, because requires its own backend database or Prefect Cloud subscription
* Bad, because not Kubernetes-native — additional integration work needed

### Temporal

Temporal is a durable workflow engine designed for long-running processes. Uses gRPC-based communication with language-specific SDKs.

* Good, because extremely reliable — designed for mission-critical workflows
* Good, because supports long-running workflows with durable state
* Good, because active CNCF project
* Bad, because requires its own persistence layer (Cassandra, MySQL, or PostgreSQL) — same database issue as Kestra
* Bad, because requires writing workflow code in Go, Java, Python, or TypeScript — not YAML-first
* Bad, because heavier operational footprint than Argo Workflows
* Bad, because overkill for ETL scheduling — designed for complex stateful business processes

## More Information

- Argo Workflows documentation: https://argo-workflows.readthedocs.io/
- Argo Helm charts: https://github.com/argoproj/argo-helm
- CNCF Argo project: https://www.cncf.io/projects/argo/
- Supersedes: [ADR-0001: Kestra over Airflow](0001-kestra-over-airflow.md)

## Traceability

- **PRD**: [PRD.md](../PRD.md)
- **DESIGN**: [DESIGN.md](../DESIGN.md)

This decision directly addresses the following requirements and design elements:

* `cpt-insightspec-fr-ing-kestra-scheduling` — Argo CronWorkflows replace Kestra's schedule triggers with cron expressions
* `cpt-insightspec-fr-ing-kestra-dependency` — Argo DAG templates define task dependencies declaratively (sync→transform)
* `cpt-insightspec-fr-ing-kestra-retry` — Argo `retryStrategy` provides configurable retry policies per WorkflowTemplate
* `cpt-insightspec-usecase-ing-scheduled-run` — The full extract-transform cycle is orchestrated as an Argo DAG workflow

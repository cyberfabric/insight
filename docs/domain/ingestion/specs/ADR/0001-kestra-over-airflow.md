---
status: proposed
date: 2026-03-23
---

# ADR-0001: Use Kestra over Airflow for Pipeline Orchestration

**ID**: `cpt-insightspec-adr-ing-kestra-over-airflow`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Apache Airflow](#apache-airflow)
  - [Kestra](#kestra)
  - [Prefect](#prefect)
  - [Custom Orchestrator (Previous Internal Design)](#custom-orchestrator-previous-internal-design)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

The Insight platform's ingestion layer needs a workflow orchestrator to schedule Airbyte connector syncs, manage dependencies between extraction and dbt transformation tasks, handle retries on transient failures, and provide execution observability. A previous custom Orchestrator was designed (docs/components/orchestrator/specs/PRD.md) but never built. The team now evaluates open-source alternatives. Key constraint: the team prefers YAML-based declarative tooling and wants to avoid Python as a required language for pipeline definitions.

## Decision Drivers

* Team does not want Python as a required language for pipeline definitions — Airflow requires Python for DAG authoring
* YAML-based declarative configuration preferred for consistency with Airbyte manifests, Terraform HCL, and Kubernetes manifests
* Must integrate with Airbyte API for triggering syncs and monitoring completion
* Must integrate with dbt CLI for triggering transformations
* Must support Kubernetes-native deployment via Helm
* Must support scheduling, task dependency management, retry policies, and execution observability
* Must be open-source with a permissive license compatible with commercial use
* Simpler operational footprint preferred — fewer moving parts than Airflow's scheduler/webserver/workers/metadata-DB architecture

## Considered Options

1. **Apache Airflow**
2. **Kestra**
3. **Prefect**
4. **Custom Orchestrator (previous internal design)**

## Decision Outcome

Chosen option: **Kestra**, because it is the only option that meets all decision drivers: YAML-first flow definitions with no Python requirement, built-in Airbyte and dbt plugins, Kubernetes-native deployment, simpler operational architecture (single binary + database), and permissive Apache 2.0 license.

### Consequences

* Good, because YAML-only flow definitions — consistent with team's tooling preferences (Airbyte manifests, Terraform, K8s)
* Good, because no Python dependency for orchestration layer
* Good, because built-in Airbyte plugin for sync triggering and monitoring
* Good, because built-in dbt plugin for transformation triggering
* Good, because simpler operational architecture than Airflow (no separate scheduler/webserver/workers)
* Good, because built-in UI for monitoring, manual triggers, and flow management
* Good, because Kubernetes-native execution model
* Good, because Apache 2.0 license — compatible with commercial use
* Bad, because smaller community than Airflow (fewer StackOverflow answers, blog posts, tutorials)
* Bad, because less mature plugin ecosystem — some integrations may require custom development
* Bad, because team must learn Kestra-specific concepts (flows, triggers, tasks, namespaces)
* Bad, because fewer managed hosting options compared to Airflow (AWS MWAA, GCP Cloud Composer)

### Confirmation

Confirmed when:

- A Kestra flow successfully triggers an Airbyte sync for a test connector, waits for completion, then triggers `dbt run` for the corresponding Bronze-to-Silver models
- The flow retries automatically on transient Airbyte API failure (HTTP 5xx)
- Kestra is deployed on Kubernetes via official Helm chart with external database

## Pros and Cons of the Options

### Apache Airflow

Apache Airflow is the most widely adopted open-source workflow orchestrator, maintained by the Apache Foundation. DAGs (Directed Acyclic Graphs) are defined in Python. Licensed under Apache 2.0.

* Good, because largest community and most mature ecosystem — extensive documentation, StackOverflow coverage, third-party providers
* Good, because official providers exist for Airbyte (`apache-airflow-providers-airbyte`), dbt (`apache-airflow-providers-dbt-cloud`), and ClickHouse
* Good, because multiple Kubernetes execution modes (KubernetesExecutor, CeleryKubernetesExecutor)
* Good, because managed hosting available (AWS MWAA, GCP Cloud Composer, Astronomer)
* Bad, because DAGs must be written in Python — team constraint explicitly excludes Python as required language
* Bad, because heavier operational footprint: separate scheduler, webserver, workers/executors, and metadata database (PostgreSQL or MySQL required)
* Bad, because metadata database does not support ClickHouse or MariaDB — requires additional PostgreSQL/MySQL instance
* Bad, because configuration drift between Python DAG code and declarative infrastructure manifests (Terraform, K8s YAML)
* Bad, because steeper learning curve for engineers without Python experience

### Kestra

Kestra is an open-source orchestration platform where workflows are defined as declarative YAML flows. Supports plugins for Airbyte, dbt, and many other tools. Licensed under Apache 2.0.

* Good, because flows are defined in YAML — no programming language required
* Good, because built-in Airbyte plugin (trigger sync, wait for completion, read status)
* Good, because built-in dbt plugin (trigger CLI commands, monitor execution)
* Good, because simpler architecture — single binary + database backend
* Good, because supports ClickHouse and MariaDB as internal storage (not just PostgreSQL)
* Good, because Kubernetes-native deployment via official Helm chart
* Good, because built-in UI for flow management, execution monitoring, and manual triggers
* Good, because event-driven triggers, schedules, and API-triggered executions
* Neutral, because younger project (founded 2022) but actively maintained with 200+ contributors
* Bad, because smaller community than Airflow — fewer examples, tutorials, and third-party integrations
* Bad, because fewer managed hosting options
* Bad, because plugin ecosystem is growing but not as comprehensive as Airflow's providers

### Prefect

Prefect is a modern Python-based workflow orchestration platform with a cloud-hosted option. Flows and tasks are defined as Python functions with decorators.

* Good, because modern Python API with clean decorator-based syntax
* Good, because Prefect Cloud provides managed hosting with observability
* Good, because good support for dynamic and parameterized workflows
* Bad, because Python-centric — same constraint as Airflow for this team
* Bad, because cloud dependency for some advanced features (Prefect Cloud)
* Bad, because less natural integration with Airbyte compared to Kestra's built-in plugin
* Bad, because self-hosted Prefect Server requires more setup than Kestra

### Custom Orchestrator (Previous Internal Design)

A custom-built orchestrator designed specifically for the Insight platform, as described in docs/components/orchestrator/specs/PRD.md. Features DAG-based task execution with typed runners and Kafka-based messaging.

* Good, because full control over design and feature set
* Good, because can be optimized for platform-specific requirements
* Bad, because significant engineering investment to build, test, and maintain — estimated months of development
* Bad, because the design was completed but implementation never started — signals feasibility concerns
* Bad, because re-invents solved problems (scheduling, retry, UI, observability, plugin ecosystem)
* Bad, because no community support — all maintenance falls on the internal team
* Bad, because opportunity cost — engineering time better spent on platform-specific differentiators

## More Information

- Kestra documentation: https://kestra.io/docs
- Kestra Airbyte plugin: https://kestra.io/plugins/plugin-airbyte
- Kestra dbt plugin: https://kestra.io/plugins/plugin-dbt
- Previous custom Orchestrator PRD: [Orchestrator PRD](../../../../components/orchestrator/specs/PRD.md) (superseded by this decision)
- Previous connector integration protocol: [ADR-0001](../../../connector/specs/ADR/0001-connector-integration-protocol.md) (superseded — Airbyte Protocol replaces stdout JSON protocol)

## Traceability

- **PRD**: [PRD.md](../PRD.md)
- **DESIGN**: [DESIGN.md](../DESIGN.md)

This decision directly addresses the following requirements and design elements:

* `cpt-insightspec-fr-ing-kestra-scheduling` — Kestra provides native scheduling with cron expressions and event-driven triggers for connector pipeline execution
* `cpt-insightspec-fr-ing-kestra-dependency` — Kestra flows define task dependencies declaratively in YAML, ensuring extract completes before transform begins
* `cpt-insightspec-fr-ing-kestra-retry` — Kestra supports configurable retry policies per task with backoff strategies
* `cpt-insightspec-usecase-ing-scheduled-run` — The full extract-transform cycle is orchestrated as a single Kestra flow

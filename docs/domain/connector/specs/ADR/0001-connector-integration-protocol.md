---
status: proposed
date: 2026-03-20
---

# ADR-0001: Use Stdout Protocol for Connector-to-System Data Delivery

**ID**: `cpt-insightspec-adr-connector-integration-protocol`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Direct Database Access](#direct-database-access)
  - [Language-Specific SDK](#language-specific-sdk)
  - [Stdout Protocol (JSON-per-line)](#stdout-protocol-json-per-line)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

The Insight platform ingests data from dozens of external sources (Microsoft 365, GitHub, Jira, Slack, etc.) through connectors. Each connector extracts data from a source API and must deliver it to the backend for storage in the Bronze layer. The backend is the authority for tenant isolation and data integrity — it enforces mandatory fields such as `tenant_id` and controls how records are persisted.

Connectors are developed by different teams in different technology stacks. The primary language is Rust, but connectors also exist in C#, Python, and TypeScript. The platform needs a single integration approach that works across all of these languages without imposing a shared runtime or library dependency.

The runner — a universal executor deployed with all available connectors — launches connectors as subprocesses, provides them with credentials and configuration obtained from the orchestrator, and is responsible for forwarding connector output to the backend API.

## Decision Drivers

* Connectors are written in multiple languages (Rust, C#, Python, TypeScript) — the integration mechanism must be language-agnostic
* The backend must enforce tenant isolation and mandatory fields (`tenant_id`, etc.) — connectors must not bypass these controls
* Connector authors should focus on extraction logic, not storage mechanics or schema details
* The runner is a universal subprocess executor — it launches any connector as a child process
* Connectors are pre-deployed with the runner at build time; updates require redeployment
* Industry alignment — the approach should follow proven patterns used by major data integration platforms

## Considered Options

1. **Direct database access** — connector reads and writes to the database directly, following agreed-upon schema rules
2. **Language-specific SDK** — connector links a Rust SDK library that provides a typed data delivery interface
3. **Stdout protocol (JSON-per-line)** — connector emits structured JSON messages to stdout; the runner reads, parses, and forwards records to the backend API

## Decision Outcome

Chosen option: **Stdout protocol (JSON-per-line)**, because it is the only option that satisfies all decision drivers simultaneously: it is fully language-agnostic, keeps data integrity control in the backend, minimizes connector complexity, and follows the integration pattern proven by the leading data integration platforms.

The protocol uses JSON-per-line message format with typed messages (RECORD, STATE, LOG, METRIC, PROGRESS). The runner reads the connector's stdout stream line by line, parses each JSON message, and routes it accordingly: RECORD messages are forwarded to the backend API for persistence, STATE messages are sent to the orchestrator for cursor management, and LOG/METRIC/PROGRESS messages are processed for observability.

### Consequences

* Good, because any language that can write JSON to stdout can implement a connector — no FFI, no shared library, no runtime dependency
* Good, because the backend enforces all data integrity rules (tenant isolation, mandatory fields, schema validation) at the API boundary — connectors cannot bypass them
* Good, because connector authors only implement extraction logic and emit records — they do not need to know about database schemas, connection pooling, or tenant routing
* Good, because the approach is battle-tested by Airbyte, Singer/Stitch, Meltano, PipelineWise, Cloudquery, and Fivetran SDK — there is extensive prior art for protocol design and tooling
* Good, because connectors are isolated subprocesses — a crash or memory leak in one connector does not affect the runner or other connectors
* Bad, because every record is serialized to JSON and deserialized by the runner, adding CPU and memory overhead compared to direct database writes
* Bad, because debugging requires inspecting the stdout stream — there is no interactive debugger attached to the protocol boundary
* Bad, because protocol evolution requires coordination between connector authors and the runner — breaking changes to message format affect all connectors

### Confirmation

Confirmed when:

- A connector implemented in Python emits RECORD and STATE messages that are correctly received by the runner, forwarded to the backend API, and persisted with the correct `tenant_id`
- A second connector implemented in a different language (Rust or TypeScript) demonstrates the same end-to-end flow without code changes to the runner
- The runner correctly handles malformed JSON lines (logs error, skips line, continues processing)

## Pros and Cons of the Options

### Direct Database Access

Connector reads and writes to the database directly using connection credentials provided by the runner. The connector follows agreed-upon schema rules (table names, column types, mandatory fields) documented in a shared specification.

* Good, because minimal latency — records go directly to storage with no intermediary
* Good, because simple architecture — no protocol layer, no message parsing
* Bad, because nothing enforces data integrity at the system level — the connector can write any data to any table, including incorrect or missing `tenant_id`
* Bad, because database schema details leak to every connector — schema changes require updating all connectors
* Bad, because database credentials must be given to the connector process, expanding the security blast radius
* Bad, because each connector must implement connection pooling, retry logic, and transaction management independently
* Bad, because monitoring what a connector writes requires database-level auditing rather than application-level observability

### Language-Specific SDK

Connector links a shared SDK library (implemented in Rust) that provides a typed interface for data delivery. The SDK handles serialization, transport, tenant context, and backend communication. Connectors in other languages use FFI bindings or language-specific wrappers generated from the Rust SDK.

* Good, because the SDK enforces data contracts at compile time (for Rust connectors) — type mismatches are caught early
* Good, because the SDK can encapsulate complex logic (batching, retry, compression) once and share it across all connectors
* Good, because the backend controls what gets written through the SDK interface — connectors cannot bypass mandatory fields
* Bad, because the SDK is written in Rust — connectors in C#, Python, and TypeScript require FFI bindings or language-specific wrappers
* Bad, because maintaining SDK bindings for 4 languages (Rust, C#, Python, TypeScript) is a significant ongoing engineering burden
* Bad, because SDK version management across languages creates coupling — a breaking SDK change requires updating and releasing all language bindings simultaneously
* Bad, because FFI boundaries introduce runtime risks (memory safety, exception handling, ABI compatibility) that are difficult to debug
* Bad, because the SDK becomes a bottleneck for connector development — new features require SDK changes before connector authors can use them

### Stdout Protocol (JSON-per-line)

Connector writes structured JSON messages to stdout, one message per line. Each message has a `type` field (RECORD, STATE, LOG, METRIC, PROGRESS) and a type-specific payload. The runner reads stdout line by line, parses the JSON, and routes each message to the appropriate destination: RECORD → backend API, STATE → orchestrator, LOG/METRIC/PROGRESS → observability.

* Good, because fully language-agnostic — any language that can write a JSON string to stdout can implement a connector
* Good, because the runner and backend enforce all data integrity rules — connectors have no direct access to the database or tenant context
* Good, because connector implementation is minimal — extract data from source, format as JSON, write to stdout
* Good, because connectors are isolated subprocesses — crashes, memory leaks, or hangs in one connector do not affect others
* Good, because this is the proven pattern used by major data integration platforms: Airbyte Protocol (JSON-per-line over stdin/stdout), Singer/Stitch (TAP/TARGET protocol), Meltano (Singer-based), PipelineWise (Singer-based, by Wise), Cloudquery (plugin-based with similar isolation), and Fivetran SDK (stdout JSON protocol for custom connectors)
* Good, because protocol messages are human-readable — easy to test a connector by running it and inspecting output
* Neutral, because protocol versioning is required — but a simple `protocol_version` field in the first message handles this
* Bad, because JSON serialization/deserialization adds CPU overhead per record — significant for high-volume connectors (millions of records per run)
* Bad, because stdout is a unidirectional channel — the runner cannot send signals back to the connector during execution (e.g., backpressure)
* Bad, because a malformed JSON line from the connector breaks the message boundary — the runner must handle parse errors gracefully

## More Information

The stdout protocol approach aligns with the execution protocol already defined in the Orchestrator PRD, which specifies typed JSON-per-line messages (LOG, STATE, METRIC, RESULT, PROGRESS) for runner-to-orchestrator communication. Adopting the same pattern for connector-to-runner communication creates a consistent message-oriented architecture across the entire pipeline.

The general workflow for a connector run:

1. Orchestrator assigns a task to the runner via Kafka
2. Runner fetches task configuration (credentials, parameters, incremental state) from the orchestrator API
3. Runner launches the connector as a subprocess, passing configuration via command-line arguments or environment variables
4. Connector extracts data from the source API and emits RECORD, STATE, LOG messages to stdout
5. Runner reads stdout, forwards RECORD messages to the backend API (which enforces `tenant_id` and persists records)
6. Runner forwards STATE messages to the orchestrator for incremental cursor persistence
7. Runner reports LOG, METRIC, and PROGRESS messages for observability

Platforms using a comparable stdout/message-based connector protocol:

| Platform | Protocol | Transport |
|----------|----------|-----------|
| Airbyte | Airbyte Protocol v2 (JSON-per-line) | stdin/stdout between containers |
| Singer / Stitch | Singer TAP/TARGET protocol | stdin/stdout |
| Meltano | Singer-based | stdin/stdout |
| PipelineWise (Wise) | Singer-based | stdin/stdout |
| Cloudquery | Plugin protocol | gRPC (conceptually similar isolation) |
| Fivetran SDK | Custom connector SDK | stdout JSON |
| dlt (data load tool) | Internal pipe pattern | Python-native, similar principles |

## Traceability

- **PRD**: [Backend PRD](../../../../components/backend/specs/PRD.md)
- **Orchestrator PRD**: [Orchestrator PRD](../../../../components/orchestrator/specs/PRD.md)
- **Connector Framework DESIGN**: [DESIGN.md](../DESIGN.md)

This decision directly addresses the following requirements and design elements:

* `cpt-orch-fr-exec-protocol` — Defines the structured execution protocol (LOG, STATE, METRIC, RESULT, PROGRESS) that this ADR extends to the connector-to-runner boundary
* `cpt-orch-fr-exec-state-report` — STATE messages from connectors flow through the runner to the orchestrator for cursor persistence
* `cpt-orch-fr-exec-metrics` — METRIC and PROGRESS messages from connectors are captured by the runner and forwarded for observability
* `cpt-orch-usecase-execute-dag` — The connector execution step within DAG task execution follows this protocol
* `cpt-orch-usecase-runner-lifecycle` — Runner subprocess management and stdout processing are defined by this decision

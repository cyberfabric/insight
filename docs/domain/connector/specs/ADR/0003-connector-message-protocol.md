---
status: proposed
date: 2026-03-27
decision-makers: antonz
---

# ADR-0003: Connector Message Protocol — Airbyte-Compatible vs Custom

**ID**: `cpt-insightspec-adr-connector-message-protocol`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Core Message Types (from Airbyte Protocol)](#core-message-types-from-airbyte-protocol)
  - [Insight-Specific Extensions](#insight-specific-extensions)
  - [Connector CLI](#connector-cli)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Option 1: Airbyte Protocol v2 (adopt as-is)](#option-1-airbyte-protocol-v2-adopt-as-is)
  - [Option 2: Singer TAP Protocol](#option-2-singer-tap-protocol)
  - [Option 3: Custom Protocol (Insight-native)](#option-3-custom-protocol-insight-native)
  - [Option 4: Airbyte-Compatible Subset (chosen)](#option-4-airbyte-compatible-subset-chosen)
- [More Information](#more-information)
  - [Protocol Version Strategy](#protocol-version-strategy)
  - [Adapter Pattern for Third-Party Connectors](#adapter-pattern-for-third-party-connectors)
  - [Relationship to ADR-0001 and ADR-0002](#relationship-to-adr-0001-and-adr-0002)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

ADR-0001 decided that connectors communicate via stdout JSON-per-line protocol, and ADR-0002 decided that connectors are thin extractors. Now we need to define the **specific message format**: what message types exist, what fields each carries, and how state is structured.

ADR-0001 mentioned five message types (RECORD, STATE, LOG, METRIC, PROGRESS) but did not define their JSON schemas, state granularity (per-stream vs global), or schema/catalog declaration. The Bitbucket Server DESIGN v2.0 uses Airbyte-style messages but the format is not standardized across the platform.

The question: should we adopt the Airbyte protocol specification as-is, define a custom protocol, or take a hybrid approach?

## Decision Drivers

* Existing connectors in the ecosystem (Airbyte has 400+ connectors) — reusing a standard protocol enables using third-party connectors with minimal adaptation
* The runner/orchestrator must parse messages reliably — a well-defined schema reduces bugs at the protocol boundary
* Connectors need to declare their available streams and schemas — the orchestrator needs this to set up Bronze tables
* Incremental sync requires structured state — per-stream cursor tracking must be unambiguous
* The orchestrator already defines its own message types (LOG, STATE, METRIC, RESULT, PROGRESS) per the Orchestrator PRD — the connector protocol should align or explicitly bridge
* Schema evolution — adding new message types or fields must not break existing connectors
* Debugging and testing — messages should be human-readable and inspectable via `| jq`

## Considered Options

1. **Airbyte Protocol v2 (adopt as-is)** — use the full Airbyte protocol specification with all 8 message types (RECORD, STATE, LOG, SPEC, CATALOG, CONNECTION_STATUS, TRACE, CONTROL)
2. **Singer TAP Protocol** — use the Singer specification with 3 message types (SCHEMA, RECORD, STATE)
3. **Custom Protocol (Insight-native)** — define a platform-specific protocol with message types tailored to the orchestrator's existing message model
4. **Airbyte-Compatible Subset** — adopt Airbyte-compatible core message types (RECORD, STATE, LOG, CATALOG, SPEC, CONNECTION_STATUS) with Insight-specific extensions, keeping compatibility with Airbyte connectors

## Decision Outcome

Chosen option: **Option 4 — Airbyte-Compatible Subset**, because it provides the best balance: we get compatibility with the Airbyte connector ecosystem (400+ existing connectors can be adapted with minimal effort), a well-defined message schema proven at scale, and the flexibility to add platform-specific extensions without being locked into Airbyte's full infrastructure.

### Core Message Types (from Airbyte Protocol)

#### RECORD — Data extraction output

```json
{"type": "RECORD", "record": {"stream": "bitbucket_team_alpha_commits", "data": {"instance_name": "team_alpha", "project_key": "RUSTLABS", "id": "abc123...", "message": "Add logging"}, "emitted_at": 1711350000000}}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"RECORD"` |
| `record.stream` | string | yes | Stream name (`{source}_{instance}_{entity}`) |
| `record.data` | object | yes | Raw extracted data as JSON object |
| `record.emitted_at` | integer | yes | Unix milliseconds when connector emitted this record |
| `record.namespace` | string | no | Optional namespace for grouping streams |

#### STATE — Incremental sync checkpoint

```json
{"type": "STATE", "state": {"type": "STREAM", "stream": {"stream_descriptor": {"name": "bitbucket_team_alpha_commits", "namespace": ""}, "stream_state": {"RUSTLABS/rust-cli-toolkit": {"main": "abc123def..."}}}, "data": {}}}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"STATE"` |
| `state.type` | string | yes | `"STREAM"` (per-stream) or `"GLOBAL"` (shared across streams) |
| `state.stream` | object | conditional | Present when `type = "STREAM"` |
| `state.stream.stream_descriptor` | object | yes | `{name, namespace}` identifying the stream |
| `state.stream.stream_state` | object | yes | Arbitrary JSON — cursor data specific to this stream |
| `state.global` | object | conditional | Present when `type = "GLOBAL"` |
| `state.global.shared_state` | object | yes | State shared across all streams |
| `state.global.stream_states` | array | yes | Array of per-stream states |
| `state.data` | object | no | Legacy format (deprecated, for backwards compatibility) |

**State granularity**: Per-stream state (`STREAM` type) is preferred. Each stream manages its own cursor independently. `GLOBAL` type is available for connectors that need cross-stream coordination (e.g., a global API rate limit counter).

#### LOG — Operational logging

```json
{"type": "LOG", "log": {"level": "INFO", "message": "Collection complete: 5 repos, 1234 commits"}}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"LOG"` |
| `log.level` | string | yes | `"FATAL"`, `"ERROR"`, `"WARN"`, `"INFO"`, `"DEBUG"`, `"TRACE"` |
| `log.message` | string | yes | Human-readable log message |
| `log.stack_trace` | string | no | Stack trace for error-level logs |

#### CATALOG — Stream schema declaration

Emitted once at startup (in response to `--discover` flag). Declares all available streams and their schemas.

```json
{"type": "CATALOG", "catalog": {"streams": [{"name": "bitbucket_team_alpha_commits", "json_schema": {"type": "object", "properties": {"id": {"type": "string"}, "message": {"type": "string"}, "author_name": {"type": "string"}}}, "supported_sync_modes": ["full_refresh", "incremental"], "source_defined_cursor": true, "default_cursor_field": ["authorTimestamp"]}]}}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"CATALOG"` |
| `catalog.streams` | array | yes | Array of stream descriptors |
| `catalog.streams[].name` | string | yes | Stream name |
| `catalog.streams[].json_schema` | object | yes | JSON Schema describing the record data shape |
| `catalog.streams[].supported_sync_modes` | array | yes | `["full_refresh"]` or `["full_refresh", "incremental"]` |
| `catalog.streams[].source_defined_cursor` | boolean | no | Whether the source defines the cursor field |
| `catalog.streams[].default_cursor_field` | array | no | Default field(s) used as cursor for incremental sync |
| `catalog.streams[].namespace` | string | no | Optional namespace |

#### SPEC — Connector configuration schema

Emitted once (in response to `--spec` flag). Declares the connector's configuration requirements.

```json
{"type": "SPEC", "spec": {"protocol_version": "1.0.0", "connectionSpecification": {"type": "object", "required": ["base_url", "instance_name", "auth_type", "credentials"], "properties": {"base_url": {"type": "string", "description": "Bitbucket Server URL"}, "instance_name": {"type": "string", "description": "Unique connector instance identifier"}}}}}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"SPEC"` |
| `spec.protocol_version` | string | yes | Insight protocol version (e.g., `"1.0.0"`) |
| `spec.connectionSpecification` | object | yes | JSON Schema for connector configuration |

#### CONNECTION_STATUS — Connectivity validation

Emitted once (in response to `--check` flag). Validates that the connector can reach the source.

```json
{"type": "CONNECTION_STATUS", "connectionStatus": {"status": "SUCCEEDED", "message": "Connected to Bitbucket Server 10.2.1 at https://git.company.com"}}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"CONNECTION_STATUS"` |
| `connectionStatus.status` | string | yes | `"SUCCEEDED"` or `"FAILED"` |
| `connectionStatus.message` | string | no | Human-readable status detail |

### Insight-Specific Extensions

Beyond the Airbyte-compatible core, the following extensions bridge to the orchestrator's existing message model:

#### METRIC — Performance telemetry (extension)

```json
{"type": "METRIC", "metric": {"name": "records_emitted", "value": 1234, "tags": {"stream": "bitbucket_team_alpha_commits"}, "timestamp": 1711350000000}}
```

Maps to the orchestrator's METRIC message type defined in the Orchestrator PRD.

#### PROGRESS — Progress reporting (extension)

```json
{"type": "PROGRESS", "progress": {"stream": "bitbucket_team_alpha_commits", "records_emitted": 500, "total_estimated": 2000, "percent": 25.0}}
```

Maps to the orchestrator's PROGRESS message type. The runner translates PROGRESS to the orchestrator's expected format.

### Connector CLI

Connectors MUST support these command-line modes:

| Command | Output | Purpose |
|---------|--------|---------|
| `connector --spec` | Single SPEC message | Declare configuration schema |
| `connector --check --config <path>` | Single CONNECTION_STATUS message | Validate connectivity |
| `connector --discover --config <path>` | Single CATALOG message | Declare available streams |
| `connector --read --config <path> --catalog <path> [--state <path>]` | Stream of RECORD, STATE, LOG messages | Extract data |

### Consequences

* Good, because any Airbyte connector can be adapted to work with Insight by wrapping its stdout — the core message types are identical
* Good, because the protocol is well-documented with existing tooling (Airbyte CDK, connector test suites)
* Good, because per-stream STATE enables fine-grained incremental sync without cross-stream coupling
* Good, because CATALOG enables the orchestrator to auto-create Bronze tables from stream schemas
* Good, because SPEC enables the orchestrator to render configuration forms without hardcoding per-connector knowledge
* Good, because METRIC and PROGRESS extensions bridge to the orchestrator's existing message model without breaking Airbyte compatibility
* Neutral, because we adopt `protocol_version` field — supports future protocol evolution
* Bad, because Airbyte protocol has some complexity we may not need immediately (namespace, global state, trace estimates)
* Bad, because adapting third-party Airbyte connectors still requires a shim to handle `instance_name` injection and stream name prefixing

### Confirmation

Confirmed when:

- A Bitbucket Server connector implements all 4 CLI modes (`--spec`, `--check`, `--discover`, `--read`) and produces valid messages
- The runner successfully parses RECORD, STATE, and LOG messages from a connector and routes them to the correct destinations
- An existing Airbyte connector (e.g., `source-github`) can be wrapped with a thin adapter that prefixes stream names with `instance_name` and its output is correctly consumed by the runner

## Pros and Cons of the Options

### Option 1: Airbyte Protocol v2 (adopt as-is)

Adopt the full Airbyte protocol specification exactly as defined, including all 7 message types, state management semantics, and CLI interface.

**Reference**: [Airbyte Protocol Documentation](https://docs.airbyte.com/understanding-airbyte/airbyte-protocol)

* Good, because maximum compatibility with 400+ existing Airbyte connectors — zero adaptation needed
* Good, because protocol is battle-tested at scale (Airbyte processes billions of records)
* Good, because comprehensive specification covers edge cases (schema evolution, state recovery, error handling)
* Bad, because some message types are Airbyte-infrastructure-specific (CONTROL for Airbyte platform features) and don't map to Insight's architecture
* Bad, because Airbyte's state management has evolved through 3 versions (LEGACY, STREAM, GLOBAL) — carrying all three adds complexity
* Bad, because no room for Insight-specific extensions (METRIC, PROGRESS) without deviating from the spec
* Bad, because Airbyte protocol assumes Docker container deployment — some semantics (volume mounts for config/catalog/state files) don't apply to subprocess model

### Option 2: Singer TAP Protocol

Adopt the Singer specification with 3 message types (SCHEMA, RECORD, STATE).

**Reference**: [Singer Specification](https://github.com/singer-io/getting-started/blob/master/docs/SPEC.md)

* Good, because extreme simplicity — only 3 message types to implement
* Good, because large existing ecosystem — 200+ taps available via Meltano
* Good, because SCHEMA message is emitted inline before records — self-describing streams
* Bad, because no structured state format — STATE value is a single opaque JSON blob, making per-stream cursor management ad-hoc
* Bad, because no SPEC or CONNECTION_STATUS — no standardized way to declare config schema or validate connectivity
* Bad, because Singer ecosystem is fragmented — many taps are unmaintained, quality varies significantly
* Bad, because no LOG message type — connector logging goes to stderr (unstructured), not the message stream
* Bad, because no incremental vs full-refresh mode declaration — sync mode is implicit per tap implementation

### Option 3: Custom Protocol (Insight-native)

Define a platform-specific protocol from scratch, using message types that map directly to the orchestrator's existing model (LOG, STATE, METRIC, RESULT, PROGRESS).

* Good, because perfect alignment with orchestrator's message model — no translation layer needed
* Good, because can be optimized for Insight's specific needs from day one
* Good, because no legacy baggage from Airbyte or Singer
* Bad, because zero ecosystem reuse — every connector must be built from scratch
* Bad, because protocol design is hard — edge cases in state management, schema evolution, and error handling take years to discover and address
* Bad, because no existing test suites, CDKs, or documentation — everything must be created
* Bad, because team members familiar with Airbyte or Singer cannot leverage that knowledge
* Bad, because "not invented here" — reinventing a solved problem

### Option 4: Airbyte-Compatible Subset (chosen)

Adopt Airbyte's core message types (RECORD, STATE, LOG, CATALOG, SPEC, CONNECTION_STATUS) with their exact JSON schemas. Add Insight-specific extensions (METRIC, PROGRESS) as additional message types. Connectors that emit only Airbyte-standard messages work without modification. The runner handles extensions gracefully — unknown message types are logged and skipped by Airbyte-native connectors.

* Good, because core messages are Airbyte-compatible — existing connectors can be adapted with minimal shim
* Good, because per-stream STATE from Airbyte is more structured than Singer's opaque blob
* Good, because CATALOG and SPEC enable orchestrator automation (auto-create tables, render config UI)
* Good, because METRIC and PROGRESS extensions bridge to the orchestrator without breaking compatibility
* Good, because the CLI interface (`--spec`, `--check`, `--discover`, `--read`) is a proven pattern for connector lifecycle management
* Good, because protocol_version field enables future evolution without breaking changes
* Neutral, because we carry some Airbyte complexity (GLOBAL state, namespace) that we may not use initially
* Bad, because adapting third-party Airbyte connectors still requires a thin wrapper for `instance_name` and stream name prefixing
* Bad, because two "extension" message types (METRIC, PROGRESS) diverge from pure Airbyte compatibility — custom connectors using these won't work with stock Airbyte

## More Information

### Protocol Version Strategy

**Airbyte Protocol reference version**: The current Airbyte protocol is at `0.18.0`. This ADR adopts a **subset** of Airbyte's message types — we do not implement the full `0.18.0` specification (which includes features like resumable full refresh, file transfer, and concurrent streams that are not needed at this stage). The subset we adopt is stable across Airbyte versions `0.3.0` through `0.18.0` — the core message types (RECORD, STATE, LOG, CATALOG, SPEC, CONNECTION_STATUS) have not changed structurally.

**Insight protocol version**: The Insight connector protocol starts at version `1.0.0`. It is versioned independently from Airbyte. The version reflects the Insight protocol maturity, not the Airbyte version it was derived from.

Future versions:
- `1.0.x` — backwards-compatible additions (new optional fields, new extension message types)
- `2.0.0` — breaking changes (field renames, removed message types, structural changes)

### Adapter Pattern for Third-Party Connectors

To use an existing Airbyte connector with Insight:

```text
┌──────────────┐    stdout    ┌──────────────┐    stdout    ┌──────────┐
│ Airbyte      │ ───────────→ │ Insight      │ ───────────→ │ Runner   │
│ Connector    │  (standard)  │ Adapter      │  (extended)  │          │
│ (unmodified) │              │ - prefix     │              │          │
│              │              │   streams    │              │          │
│              │              │ - inject     │              │          │
│              │              │   instance   │              │          │
└──────────────┘              └──────────────┘              └──────────┘
```

The adapter reads the Airbyte connector's stdout, prefixes stream names with `{instance_name}_`, injects `instance_name` into RECORD data, and emits the modified messages to its own stdout.

### Relationship to ADR-0001 and ADR-0002

| ADR | Decides | Level |
|-----|---------|-------|
| ADR-0001 | Transport: stdout JSON-per-line (vs DB, vs SDK) | Transport |
| ADR-0002 | Scope: thin extractor (vs smart connector) | Architecture |
| **ADR-0003** | **Format: Airbyte-compatible message types and schemas** | **Protocol** |

## Traceability

- **ADR-0001**: [Stdout Protocol](./0001-connector-integration-protocol.md)
- **ADR-0002**: [Connector Responsibility Scope](./0002-connector-responsibility-scope.md)
- **Domain DESIGN**: [Connector Framework DESIGN](../DESIGN.md)
- **Orchestrator PRD**: [Orchestrator PRD](../../../components/orchestrator/specs/PRD.md)

This decision directly addresses the following requirements and design elements:

* `cpt-insightspec-adr-connector-integration-protocol` — This ADR defines the specific message format that flows through the stdout channel established by ADR-0001
* `cpt-insightspec-adr-connector-responsibility-scope` — The thin extractor (ADR-0002) emits messages in the format defined here
* `cpt-orch-fr-exec-protocol` — METRIC and PROGRESS extensions align with the orchestrator's execution protocol messages
* `cpt-orch-fr-exec-state-report` — STATE message format enables the orchestrator to persist and replay incremental sync cursors

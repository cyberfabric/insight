# Connector Architecture for Metrics Layer

> Conceptual architecture for data ingestion subsystem

## Overview

This document describes the connector architecture for the Metrics Layer — the data collection and normalization subsystem of the Insight platform. The architecture is designed to support multiple data sources while maintaining a unified data model and enabling easy addition of new connectors.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           EXTERNAL DATA SOURCES                              │
├─────────────┬─────────────┬─────────────┬─────────────┬─────────────────────┤
│   Version   │    Task     │ Communication│     HR &    │     AI & Dev        │
│   Control   │  Tracking   │   Systems    │Organization │      Tools          │
├─────────────┼─────────────┼─────────────┼─────────────┼─────────────────────┤
│ GitLab      │ YouTrack    │ Zulip       │ BambooHR    │ MCP (AI Assistant)  │
│ GitHub      │ Jira        │ MS Teams    │ Workday     │ Cursor              │
│ Bitbucket   │ Linear      │ Slack       │ LDAP        │ Allure (Tests)      │
│             │             │ M365 Mail   │             │                     │
│             │             │ M365 Cal    │             │                     │
└──────┬──────┴──────┬──────┴──────┬──────┴──────┬──────┴──────────┬──────────┘
       │             │             │             │                 │
       ▼             ▼             ▼             ▼                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CONNECTOR LAYER                                     │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                         Source Adapters                               │   │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐        │   │
│  │  │ gitlab_    │ │ youtrack_  │ │ zulip_     │ │ bamboohr_  │  ...   │   │
│  │  │ connector  │ │ connector  │ │ connector  │ │ connector  │        │   │
│  │  └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘        │   │
│  │        │              │              │              │               │   │
│  │        ▼              ▼              ▼              ▼               │   │
│  │  ┌──────────────────────────────────────────────────────────────┐   │   │
│  │  │                    Extraction Cache                          │   │   │
│  │  │           (Optional per-connector staging DB)                │   │   │
│  │  │         [Local cache for incremental sync]                  │   │   │
│  │  └──────────────────────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           UNIFIER LAYER                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    Domain Unifiers (JSON Schemas)                     │   │
│  │                                                                       │   │
│  │  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐        │   │
│  │  │ Code Activity   │ │ Task Tracking   │ │ Communication   │        │   │
│  │  │    Unifier      │ │    Unifier      │ │    Unifier      │        │   │
│  │  │                 │ │                 │ │                 │        │   │
│  │  │ commit          │ │ task            │ │ message         │        │   │
│  │  │ merge_request   │ │ bug             │ │ meeting         │        │   │
│  │  │ code_review     │ │ user_story      │ │ email           │        │   │
│  │  │ loc_stats       │ │ sprint          │ │ calendar_event  │        │   │
│  │  └─────────────────┘ └─────────────────┘ └─────────────────┘        │   │
│  │                                                                       │   │
│  │  ┌─────────────────┐ ┌─────────────────┐                             │   │
│  │  │ Organization    │ │ AI & Dev        │                             │   │
│  │  │    Unifier      │ │    Unifier      │                             │   │
│  │  │                 │ │                 │                             │   │
│  │  │ person          │ │ ai_session      │                             │   │
│  │  │ department      │ │ test_result     │                             │   │
│  │  │ functional_team │ │ ide_activity    │                             │   │
│  │  │ hierarchy       │ │                 │                             │   │
│  │  └─────────────────┘ └─────────────────┘                             │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ORCHESTRATION LAYER                                   │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                         AirByte / Dagster                             │   │
│  │                                                                       │   │
│  │  • Incremental data extraction via standard interface                │   │
│  │  • Chronological cursor-based pagination                             │   │
│  │  • Retry and error handling                                          │   │
│  │  • Schedule management (cron-based)                                  │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    STORAGE & SERVING LAYER (ClickHouse)                      │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                                                                       │   │
│  │  ┌────────────────────────────────────────────────────────────────┐  │   │
│  │  │                     RAW TABLES                                  │  │   │
│  │  │  raw_gitlab_commits | raw_youtrack_issues | raw_zulip_messages │  │   │
│  │  │  raw_m365_reports   | raw_bamboohr_users  | raw_mcp_sessions   │  │   │
│  │  └────────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                        │   │
│  │                              ▼                                        │   │
│  │  ┌────────────────────────────────────────────────────────────────┐  │   │
│  │  │                    dbt TRANSFORMATIONS                         │  │   │
│  │  │         Staging → Intermediate → Mart                         │  │   │
│  │  └────────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                        │   │
│  │                              ▼                                        │   │
│  │  ┌────────────────────────────────────────────────────────────────┐  │   │
│  │  │                    DATA MARTS                                   │  │   │
│  │  │  mart_dev_activity | mart_task_flow | mart_communication      │  │   │
│  │  │  mart_people       | mart_ai_usage  | mart_aggregated_facts   │  │   │
│  │  └────────────────────────────────────────────────────────────────┘  │   │
│  │                              │                                        │   │
│  │                              ▼                                        │   │
│  │  ┌────────────────────────────────────────────────────────────────┐  │   │
│  │  │                 MATERIALIZED VIEWS (Serving)                   │  │   │
│  │  │  • Pre-aggregated views for dashboard queries                  │  │   │
│  │  │  • Dictionaries for dimension lookups                          │  │   │
│  │  │  • Projection-based optimization for common access patterns    │  │   │
│  │  └────────────────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    IDENTITY RESOLUTION LAYER                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                                                                       │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       │   │
│  │  │  Person Registry │  │ Alias Mappings  │  │  Merge Rules    │       │   │
│  │  │  (Canonical ID)  │  │ (email→person)  │  │  (auto+manual)  │       │   │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘       │   │
│  │                                                                       │   │
│  │  • System-agnostic identity resolution                               │   │
│  │  • Multi-alias support (one person → many emails/usernames)          │   │
│  │  • Fuzzy name matching + email normalization                         │   │
│  │  • Unmapped queue for manual resolution                              │   │
│  │  • Stored as ClickHouse Dictionaries for fast JOINs                  │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            API LAYER                                         │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  • REST/GraphQL API for Analytics Layer                              │   │
│  │  • Row-level security via application layer                          │   │
│  │  • Query parameterization for org-tree filtering                     │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                         ┌─────────────────────┐
                         │   ANALYTICS LAYER   │
                         │   (Consumer of      │
                         │    Metrics Layer)   │
                         └─────────────────────┘
```

## Connector Contract

Each connector must implement a standardized interface that enables incremental data extraction:

### Interface Specification

```yaml
connector:
  id: string                    # Unique connector identifier
  name: string                  # Human-readable name
  version: string               # Semantic version
  source_type: string           # Category: git | task | communication | hr | ai
  
  config:
    required_env_vars: []       # List of required environment variables
    optional_env_vars: []       # List of optional configuration
    
  capabilities:
    incremental_sync: boolean   # Supports cursor-based extraction
    full_refresh: boolean       # Supports full data reload
    schema_discovery: boolean   # Can detect schema changes
    
  endpoints:
    - name: string              # Endpoint name (e.g., "commits", "issues")
      entity_type: string       # Unified entity type (maps to Unifier)
      cursor_field: string      # Field used for incremental sync (e.g., "updated_at")
      primary_key: string       # Unique identifier field
```

### Extraction API

```
GET /extract?cursor={timestamp}&limit={n}

Response:
{
  "data": [...],           # Array of records
  "next_cursor": string,   # Cursor for next page
  "has_more": boolean      # More data available
}
```

## Unifier Schemas with Semantic Metadata

Unifiers define the canonical data models that normalize disparate source systems into unified formats. **Critically, each field includes semantic metadata that automatically propagates to the Semantic Dictionary in the Analytics Layer.**

### Semantic Metadata Structure

Each field in the Unifier schema includes semantic annotations:

```yaml
field:
  name: string                    # Technical field name
  type: string                    # Data type
  
  # === SEMANTIC METADATA (propagates to Semantic Dictionary) ===
  semantic:
    display_name: string          # Human-readable name for UI
    description: string           # What this field measures/represents
    category: string              # Domain category (code, communication, task, etc.)
    
    # Aggregation rules
    aggregation:
      type: enum [SUM, AVG, COUNT, MAX, MIN, LAST, NONE]
      time_grain: enum [daily, weekly, monthly, quarterly]
      
    # Display formatting
    format:
      pattern: string             # e.g., "#,##0", "0.0%", "HH:mm"
      unit: string                # e.g., "lines", "hours", "messages"
      
    # Business context
    concepts: [string]            # Related business concepts
    applicable_teams: [string]    # Which functional teams use this metric
    
    # Data lineage hint
    lineage:
      upstream: [string]          # Source tables/fields
      calculation: string         # Formula or transformation description
```

### Unifier Domains

The system supports an extensible set of domains. Each domain defines a set of unified entities:

| Domain | Entities | Concepts | Example Sources |
|--------|----------|----------|-----------------|
| **code** | commit, merge_request, code_review, branch | Code Output, Velocity, Review Quality | GitLab, GitHub, Bitbucket |
| **task** | task, bug, user_story, epic, sprint | Delivery, Task Flow, Capacity | YouTrack, Jira, Linear |
| **communication** | message, meeting, email, calendar_event | Communication Load, Sync Tax, Collaboration | Zulip, Slack, MS Teams, M365 |
| **organization** | person, functional_team, department, hierarchy | Identity, Org Structure, Cohort | BambooHR, Workday, LDAP |
| **ai_tools** | ai_session, prompt, completion | AI Leverage, Automation | MCP, Cursor, Copilot |
| **quality** | test_result, coverage, incident | Stability, Quality | Allure, Sentry |

### Extensibility Model

Adding a new domain or entity:

```
1. Define domain.yaml:
   ┌────────────────────────────────────────┐
   │ domain: <domain_id>                    │
   │ description: "..."                     │
   │ entities:                              │
   │   <entity_name>:                       │
   │     semantic: { ... }                  │
   │     fields: [ ... ]                    │
   └────────────────────────────────────────┘

2. For each field specify:
   ┌────────────────────────────────────────┐
   │ - name: <field_name>                   │
   │   type: <data_type>                    │
   │   source_mappings:                     │
   │     <source>: "<path.to.field>"        │
   │   semantic:                            │
   │     display_name: "..."                │
   │     description: "..."                 │
   │     aggregation: { type: ..., ... }    │
   │     concepts: [ ... ]                  │
   │     applicable_teams: [ ... ]          │
   └────────────────────────────────────────┘

3. Register in schema registry
4. Connectors automatically use mappings
5. Semantic metadata → Data Catalog → Semantic Dictionary
```

### Source Mappings

Each field can have mappings from different sources:

```
Unified Field         Source System Paths
──────────────────────────────────────────────────────
task.id           →   youtrack: "idReadable"
                      jira: "key"
                      linear: "identifier"

commit.author     →   gitlab: "author_email"
                      github: "commit.author.email"
                      bitbucket: "author.raw"

meeting.duration  →   m365: "end - start"
                      google: "endTime - startTime"
```

When adding a new source, just add a mapping — the unified data structure remains unchanged.

## Semantic Metadata Propagation

The semantic metadata defined in Unifier schemas automatically flows to the Analytics Layer:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CONNECTOR/UNIFIER LAYER                               │
│                                                                              │
│  Unifier Schema                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  field: loc_added                                                    │   │
│  │  semantic:                                                           │   │
│  │    display_name: "LOC Added"                                        │   │
│  │    description: "Lines of code added in this commit"                │   │
│  │    aggregation: { type: SUM }                                       │   │
│  │    concepts: ["Code Output", "Velocity"]                            │   │
│  │    applicable_teams: ["Dev-Backend", "Dev-Frontend"]                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Schema Sync (automated)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          DATA CATALOG                                        │
│                       (Metrics Layer)                                        │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  data_field: loc_added                                               │   │
│  │  data_source: mart_dev_activity                                     │   │
│  │  data_type: Int64                                                   │   │
│  │  semantic_metadata: { ... inherited from Unifier ... }              │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Metadata API
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     SEMANTIC DICTIONARY                                      │
│                    (Analytics Layer)                                         │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  metric: "LOC Added"                                                 │   │
│  │  ├── mapped_to: data_field[loc_added]                               │   │
│  │  ├── display_name: "LOC Added"           ◄── from Unifier           │   │
│  │  ├── description: "Lines of code..."     ◄── from Unifier           │   │
│  │  ├── aggregation_type: SUM               ◄── from Unifier           │   │
│  │  ├── concepts: ["Code Output"]           ◄── from Unifier           │   │
│  │  ├── applicable_teams: [...]             ◄── from Unifier           │   │
│  │  │                                                                   │   │
│  │  │  ┌─────────────────────────────────────────────────────────┐    │   │
│  │  │  │ ANALYST ENRICHMENT (manual additions)                    │    │   │
│  │  │  │  • threshold_warning: 5000                               │    │   │
│  │  │  │  • threshold_critical: 10000                             │    │   │
│  │  │  │  • business_context: "High values may indicate..."       │    │   │
│  │  │  │  • related_patterns: ["Gold Plating"]                    │    │   │
│  │  │  └─────────────────────────────────────────────────────────┘    │   │
│  │  │                                                                   │   │
│  └──┴───────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Propagation Rules

| Unifier Field | Propagates To | Override Policy |
|---------------|---------------|-----------------|
| `display_name` | Semantic Dictionary → metric.display_name | Analyst can override |
| `description` | Semantic Dictionary → metric.description | Analyst can extend |
| `category` | Data Catalog → field.category | Immutable |
| `aggregation.type` | Semantic Dictionary → metric.aggregation_type | Analyst can override |
| `format.pattern` | Semantic Dictionary → metric.format_pattern | Analyst can override |
| `concepts` | Semantic Dictionary → metric.concepts (initial set) | Analyst can add more |
| `applicable_teams` | Semantic Dictionary → metric.applies_to (initial set) | Analyst can modify |
| `lineage.calculation` | Data Catalog → field.calculation_hint | Immutable |

### Benefits of Connector-Level Semantics

1. **Single Source of Truth**: Descriptions defined once at extraction point
2. **Consistency**: Same field always described the same way across all consumers
3. **Developer Efficiency**: New connectors automatically populate semantic layer
4. **Reduced Manual Work**: Analysts only add business-specific enrichments
5. **Auditability**: Clear lineage from source field to metric definition
6. **AI Context**: AI agents receive full context without separate dictionary lookup

## Data Flow Patterns

### Pattern 1: API-Based Extraction (Standard)

```
┌──────────────┐    HTTP/API     ┌────────────────┐    AirByte    ┌────────────┐
│ Source API   │ ───────────────▶│ Connector Pod  │ ────────────▶ │ ClickHouse │
│ (Jira, M365) │                 │ (Stateless)    │               │ (Raw Table)│
└──────────────┘                 └────────────────┘               └────────────┘
```

### Pattern 2: File-Based Extraction (Git)

```
┌──────────────┐   Clone/Pull    ┌────────────────┐   Parse     ┌──────────────┐
│ GitLab/GitHub│ ───────────────▶│ Local Disk     │ ──────────▶ │ ClickHouse   │
│ (Repositories│                 │ (Git Repos)    │             │ (Raw Table)  │
└──────────────┘                 └────────────────┘             └──────────────┘
```

### Pattern 3: Webhook-Based (Real-time)

```
┌──────────────┐   Webhook      ┌────────────────┐   Queue     ┌──────────────┐
│ Source System│ ─────────────▶ │ Webhook Handler│ ──────────▶ │ Kafka/Queue  │
│ (YouTrack)   │                │                │             │              │
└──────────────┘                └────────────────┘             └──────┬───────┘
                                                                      │
                                                                      ▼ Consumer
                                                               ┌──────────────┐
                                                               │ ClickHouse   │
                                                               │ (Raw Table)  │
                                                               └──────────────┘
```

## Connector Implementation Guidelines

### 1. Connector Structure

```
connectors/
├── gitlab/
│   ├── connector.yaml          # Connector manifest
│   ├── src/
│   │   ├── client.py           # API client
│   │   ├── extractor.py        # Data extraction logic
│   │   └── transformer.py      # Mapping to unified schema
│   ├── tests/
│   └── Dockerfile
├── youtrack/
│   ├── connector.yaml
│   ├── src/
│   └── ...
└── _shared/
    ├── base_connector.py       # Base class
    ├── http_utils.py           # Common HTTP utilities
    └── schema_registry.py      # Unified schema definitions
```

### 2. Development Principles

1. **Stateless by Default**: Connectors should not maintain internal state; use cursor-based pagination
2. **Idempotent Operations**: Re-running with the same cursor should produce the same results
3. **Schema Versioning**: Track schema changes with semantic versioning
4. **Error Isolation**: One connector failure should not affect others
5. **Rate Limiting**: Respect source system rate limits; implement exponential backoff

### 3. Adding a New Connector

1. **Create connector manifest** (`connector.yaml`) — define source, endpoints, capabilities
2. **Define Unifier mapping with semantic metadata**:
   - Map source fields to unified entity fields
   - Add `semantic` block for each field (display_name, description, aggregation, concepts)
   - Define applicable_teams and format patterns
3. **Implement source adapter** extending base class
4. **Add dbt staging model** for the new source with descriptions
5. **Update Identity Resolution** with new alias sources (email/username mappings)
6. **Register in AirByte/Dagster** orchestrator
7. **Trigger Data Catalog sync** — semantic metadata flows to Semantic Dictionary
8. **Analyst review** — approve auto-generated metrics or add enrichments

```
New Connector Checklist:
┌──────────────────────────────────────────────────────────────────┐
│ □ connector.yaml — manifest with endpoints                       │
│ □ unifier_mapping.yaml — field mappings + semantic metadata      │
│ □ src/client.py — API client                                     │
│ □ src/extractor.py — data extraction                             │
│ □ src/transformer.py — apply unifier mapping                     │
│ □ dbt/staging/stg_{source}.sql — staging model                   │
│ □ dbt/staging/stg_{source}.yml — dbt docs + tests               │
│ □ identity/aliases_{source}.yaml — identity resolution rules     │
│ □ tests/ — unit and integration tests                            │
│ □ Dockerfile — containerized deployment                          │
└──────────────────────────────────────────────────────────────────┘
```

## Data Catalog Integration

The connector layer automatically populates the Data Catalog with both technical and semantic metadata:

```
┌─────────────────────────────────────────────────────────────────┐
│                        DATA CATALOG                              │
│                                                                  │
│  Automatically Populated from Connectors/Unifiers:              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  TECHNICAL METADATA                                        │  │
│  │  • Table names, schemas, row counts                        │  │
│  │  • Column definitions (name, type, nullable)               │  │
│  │  • Source system identifiers                               │  │
│  │  • Last sync timestamps, freshness                         │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │  SEMANTIC METADATA (from Unifier schemas)                  │  │
│  │  • display_name, description                               │  │
│  │  • category, aggregation rules                             │  │
│  │  • format patterns, units                                  │  │
│  │  • concepts, applicable_teams                              │  │
│  │  • lineage hints (calculation formulas)                    │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Populated from dbt:                                            │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  • Model dependencies (transformation lineage)             │  │
│  │  • Test definitions and results                            │  │
│  │  • Model documentation                                     │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Metadata Sync API
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    SEMANTIC DICTIONARY                           │
│                    (Analytics Layer)                             │
│                                                                  │
│  PRE-POPULATED from Connector Semantic Metadata:                │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  • Metrics with display names ◄── Unifier.semantic        │  │
│  │  • Descriptions ◄── Unifier.semantic.description          │  │
│  │  • Aggregation types ◄── Unifier.semantic.aggregation     │  │
│  │  • Concept links ◄── Unifier.semantic.concepts            │  │
│  │  • Team applicability ◄── Unifier.semantic.applicable_teams│ │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ENRICHED by Business Analysts (manual additions):              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  • Thresholds and benchmarks                               │  │
│  │  • Business context and interpretation guidance            │  │
│  │  • Pattern/alert configurations                            │  │
│  │  • Custom derived metrics                                  │  │
│  │  • Override display names if needed                        │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Sync Workflow

1. **Connector Registration**: When a new connector is added, its Unifier schema is registered
2. **Schema Extraction**: Data Catalog extracts field definitions + semantic metadata
3. **Initial Population**: Semantic Dictionary receives baseline metrics with full context
4. **Discovery Engine**: Flags new fields for analyst review (high confidence auto-approved)
5. **Analyst Enrichment**: Business analysts add thresholds, patterns, custom context
6. **Activation**: Metrics become available in dashboards and AI queries

## Security Considerations

1. **Credential Management**: All secrets via environment variables or secret manager
2. **Data Privacy**: 
   - Private message content never extracted (only metadata)
   - PII handling according to data classification
3. **Access Logging**: All data access logged for audit
4. **Network Isolation**: Connectors run in isolated containers
5. **Rate Limiting**: Prevent overloading source systems

## References

- [PRODUCT_SPECIFICATION.md](./PRODUCT_SPECIFICATION.md) — Full product specification
- [PRODUCT_SPECIFICATION.md](./PRODUCT_SPECIFICATION.md) — Product vision document

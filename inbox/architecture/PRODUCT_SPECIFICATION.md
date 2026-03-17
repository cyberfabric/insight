# Insight: Product Specification

> Decision Intelligence Platform

## Executive Summary

Insight is a decision intelligence platform that transforms operational and learning signals into trusted, actionable insights. Unlike traditional BI tools that merely visualize data, Insight enforces shared meaning, promotes trustworthy metrics, and provides governed AI exploration. It serves as the cognitive core for organizational productivity and educational performance, enabling leaders to understand why outcomes change, not just what happened.

The platform consists of **two independent layers**:

1. **Metrics Layer** — Collects, normalizes, and stores data from external systems. Handles identity resolution and provides a stable data API.

2. **Analytics Layer** — Provides semantic governance, AI-powered analysis, dashboards, and chat-based exploration. Consumes data from the Metrics Layer.

This separation enables independent scaling, clear ownership, and technology flexibility. The same Metrics Layer can serve multiple Analytics instances (corporate, education, portfolio companies).

## Product Vision (3-Year Horizon)

Insight evolves from a prototype-driven analytics tool into the default decision layer for productivity, coordination, and learning health. The three-year destination is defined by three outcomes:

1. **Unified Data Foundation** - Normalizes heterogeneous systems into shared entities and events
2. **Verified Analytics** - Makes every KPI traceable and explainable with full data lineage
3. **AI-Guided Exploration** - AI operates only within governance rules and the semantic dictionary

### Data Volume Assumptions

Insight's architecture is designed for **50M+ rows over 3 years** based on the following projections:

**Event Generation Rates (per employee per year):**
- Development activity (Git, MCP): ~3,500 events
- Project management (YouTrack/Jira): ~5,000 events
- Communication (M365, Zulip): ~8,000 events
- HR & presence (BambooHR/Workday, attendance): ~500 events
- **Subtotal (current sources):** ~17,000 events/employee/year
- Planned integrations (Confluence, Cursor AI): ~2,000 events
- **Total with planned:** ~19,000 events/employee/year

**Deployment Phases:**
- **Year 1:** 300 employees (Constructor) → 5.1M rows
- **Year 3:** 1,000 employees (portfolio) → 33M cumulative rows
- **Year 5:** 1,000 employees + 5,000 students → 120M cumulative rows

📊 **Full analysis:** See [STORAGE_TECHNOLOGY_EVALUATION.md](./STORAGE_TECHNOLOGY_EVALUATION.md#data-volume-projections) for detailed breakdown by data source.

## What Insight Is (And Is Not)

### What It Is

- A decision intelligence platform with governed semantics at its core
- A system that unifies data from any source into a shared semantic model
- A platform providing both dashboards and conversational AI interface
- A "single source of truth" for decision makers

### What It Is Not

- **Not a generic BI tool** - It enforces shared meaning, not just visualizations
- **Not a replacement for transactional systems** - It analyzes, doesn't execute
- **Not an automated judgment system** - Insights are recommendations, not directives
- **Not a system without human oversight** - Full transparency and traceability are core principles

## Target Users

### Corporate Segment

| User Role | Primary Need |
|-----------|--------------|
| Executive Leadership | Consistent metrics across teams and portfolio companies |
| Portfolio Owners | Cross-company benchmarking with comparable definitions |
| Operational Leaders | Early warnings on coordination and productivity risks |
| Engineering Managers | Team performance visibility and anomaly detection |
| Sales Managers | Rep activity volume, pipeline health, and outreach productivity |
| Marketing Leaders | Campaign activity, lead generation, and funnel contribution |
| Operations Leaders | Cross-functional workflow efficiency and throughput |

> **Principle: Measure all employees, not just engineers.** Engineering headcount is typically a minority of the total workforce — for example, at Acronis, engineers are ~26% of headcount and ~15% of costs. Limiting measurement to engineering roles means the majority of the organization remains a blind spot. Insight is designed to measure productivity signals across all employee functions using domain-appropriate metrics for each role.

### Education Segment

| User Role | Primary Need |
|-----------|--------------|
| University Program Directors | Cohort health monitoring, at-risk student identification |
| LPE Operators | Learner engagement and progress tracking |
| Education Leaders | Explainable indicators of churn risk across programs |

## System Architecture

Insight is built as **two distinct product layers** that can be deployed and scaled independently:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│                    ANALYTICS LAYER                               │
│              (Analysis & Visualization)                          │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    OUTPUT LAYER                            │  │
│  │      BI Dashboards  │  Chat UI  │  Alerts & Reports       │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │                     AI LAYER                               │  │
│  │  MCP Query Tools  │  Visualization  │  Insights Generator │  │
│  ├─────────────────────────┬─────────────────────────────────┤  │
│  │   STATIC ANALYZER       │    BUSINESS SEMANTICS           │  │
│  │  Verified SQL Scripts   │   Metrics, Concepts, Patterns,  │  │
│  │  Curated Reports        │   Teams, Thresholds             │  │
│  └─────────────────────────┴─────────────────────────────────┘  │
│                              ▲                                   │
│                              │ API + Metadata Sync               │
└──────────────────────────────┼───────────────────────────────────┘
                               │
┌──────────────────────────────┼───────────────────────────────────┐
│                              │                                    │
│                    METRICS LAYER                                  │
│               (Collection & Storage)                              │
│                              │                                    │
│  ┌───────────────────────────┴───────────────────────────────┐   │
│  │                    DATA CATALOG                            │   │
│  │   Tables, Columns, Types  │  dbt Models & Lineage          │   │
│  ├────────────────────────────────────────────────────────────┤   │
│  │                   DATA VIEW LAYER                          │   │
│  │       Aggregated Data Marts  │  Materialized Views         │   │
│  ├────────────────────────────────────────────────────────────┤   │
│  │                IDENTITY RESOLUTION LAYER                   │   │
│  │    Person Registry  │  Alias Mappings  │  Merge Rules      │   │
│  ├────────────────────────────────────────────────────────────┤   │
│  │                    STORAGE LAYER                           │   │
│  │         ClickHouse Data Warehouse + dbt Transforms         │   │
│  ├────────────────────────────────────────────────────────────┤   │
│  │                  INTEGRATION LAYER                         │   │
│  │                Connectors  │  Unifiers                     │   │
│  └────────────────────────────────────────────────────────────┘   │
│                              ▲                                    │
│                              │                                    │
└──────────────────────────────┼────────────────────────────────────┘
                               │
                    ┌──────────┴──────────┐
                    │   External Systems   │
                    │ Git, Jira, M365, HR  │
                    └─────────────────────┘
```

### Semantic Layer Distribution

The semantic information is distributed across both layers:

| Layer | Component | Contains |
|-------|-----------|----------|
| **Metrics Layer** | Data Catalog | Tables, columns, data types, dbt models, transformation lineage |
| **Analytics Layer** | Business Semantics | Metrics, concepts, patterns, teams, thresholds, display rules |

**Data Catalog** (Metrics Layer) provides the foundation — what data exists and how it flows. **Business Semantics** (Analytics Layer) adds meaning — what the data means for business decisions.

The Analytics Layer syncs metadata from Data Catalog and enriches it with business context.

---

## Layer 1: Metrics Layer (Collection & Storage)

The Metrics Layer is responsible for **data ingestion, normalization, identity resolution, and storage**. It operates independently and can serve multiple Analytics Layer instances.

### Key Responsibilities

- Collect data from external systems via connectors
- Normalize heterogeneous data into unified schemas
- Resolve and merge person identities across systems
- Store and transform data for analytical consumption
- **Maintain Data Catalog** with table/column metadata and dbt lineage
- Provide stable API for data access and metadata sync

### Integration Layer (Sources & Standardization)

Entry point for data collection with **Unifiers** as the key concept:

- **Connectors**: Plug-in adapters for each data source (Git, Jira, YouTrack, Zulip, M365, BambooHR, etc.)
- **Unifiers**: Normalize disparate systems into unified format via JSON schemas
  - Example: Tasks from Jira and YouTrack transform into unified `Task` objects
  - Example: Employee records from Git, M365, BambooHR normalize into unified `Person` entities

### Storage & Transformation Layer

ClickHouse serves as the unified analytical storage:

- **ClickHouse Data Warehouse**: Primary storage for raw data and all transformations
- **dbt Models**: Transform raw data into normalized facts and aggregated marts
- **Materialized Views**: Pre-computed aggregations for fast dashboard queries
- **Data Marts**: Curated views for final analytics processing

### Identity Resolution Layer

Dedicated layer for resolving and merging person identities across all connected systems:

- **Person Registry**: Canonical person records with system-generated UUIDs
- **Alias Mappings**: Links between person records and source system identifiers (emails, usernames, employee IDs)
- **Merge Rules**: Configurable automatic matching + manual override capability
- **Unmapped Queue**: Unknown identities flagged for manual resolution

This layer is system-agnostic — it doesn't depend on any specific HR system as the "source of truth". Any identity source (BambooHR, Workday, LDAP, or manual import) can be used.

### Data View Layer

Curated views optimized for analytical consumption:

- **Aggregated Data Marts**: Pre-joined tables with business logic applied
- **Materialized Views**: Real-time aggregations for common queries
- **API Endpoints**: Stable interface for Analytics Layer consumption

### Data Catalog

Central registry of all data assets in the Metrics Layer:

```
┌─────────────────────────────────────────────────────────────────┐
│                        DATA CATALOG                              │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  DATA SOURCES                                                ││
│  │  • Table name, schema, row count, last updated              ││
│  │  • Column definitions (name, type, nullable)                ││
│  │  • Primary keys, foreign keys, indexes                      ││
│  └─────────────────────────────────────────────────────────────┘│
│                              │                                   │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  DBT MODELS                                                  ││
│  │  • Model name, materialization (view/table/incremental)     ││
│  │  • SQL definition, description                              ││
│  │  • Tests (uniqueness, not_null, accepted_values)            ││
│  └─────────────────────────────────────────────────────────────┘│
│                              │                                   │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  TRANSFORMATION LINEAGE                                      ││
│  │  • Source → Staging → Mart dependencies                     ││
│  │  • Column-level lineage (which source feeds which column)   ││
│  │  • Freshness metadata (last run, next scheduled)            ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

**Data Catalog provides:**

| Capability | Description |
|------------|-------------|
| **Schema Discovery** | Auto-detect new tables and columns |
| **dbt Integration** | Import model definitions, tests, and docs |
| **Lineage Tracking** | Trace data flow from source to mart |
| **Freshness Monitoring** | Track when data was last updated |
| **API for Analytics** | Expose metadata for Business Semantics sync |

**Syncing with Analytics Layer:**

The Analytics Layer Discovery Engine pulls metadata from Data Catalog and suggests business semantics (display names, categories, aggregation types) for human review.

---

## Layer 2: Analytics Layer (Analysis & Visualization)

The Analytics Layer is responsible for **semantic governance, AI-powered analysis, and user-facing interfaces**. It consumes data from the Metrics Layer API.

### Key Responsibilities

- Define and govern semantic meaning of metrics
- Provide AI-powered exploration and insights
- Generate dashboards, reports, and alerts
- Enable chat-based data interaction

### Business Semantics (Knowledge Graph)

The Business Semantics layer is a **knowledge graph** that adds business meaning to the technical metadata from Data Catalog. It serves as the "Source of Truth" for metric definitions and governance.

**How it connects to Data Catalog:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    BUSINESS SEMANTICS                            │
│                  (Analytics Layer)                               │
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │   Metrics   │  │  Concepts   │  │  Patterns   │              │
│  │ (LOC Added) │  │(Code Quality│  │ (Burnout)   │              │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │                │                │                      │
│         │    MAPPED_TO   │  MEASURED_BY   │  TRIGGERS            │
│         ▼                ▼                ▼                      │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │               Synced from Data Catalog                       ││
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐    ││
│  │  │ data_source   │  │ data_field    │  │ dbt_model     │    ││
│  │  │ (dev_summary) │  │ (loc_added)   │  │ (mart_people) │    ││
│  │  └───────────────┘  └───────────────┘  └───────────────┘    ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                               ▲
                               │ Metadata Sync
                               │
┌──────────────────────────────┴──────────────────────────────────┐
│                      DATA CATALOG                                │
│                   (Metrics Layer)                                │
│                                                                  │
│  Tables, Columns, Types, dbt Models, Transformation Lineage     │
└─────────────────────────────────────────────────────────────────┘
```

**Entity Types (Nodes):**

| Entity Type | Source | Description |
|-------------|--------|-------------|
| `data_source` | Data Catalog | Table or view in database |
| `data_field` | Data Catalog | Column with type and aggregation rules |
| `dbt_model` | Data Catalog | dbt transformation with lineage |
| `metric` | Business Semantics | Aggregatable measurement with display formatting |
| `concept` | Business Semantics | Business domain area (e.g., "Code Quality") |
| `team` | Business Semantics | Functional team with category and mission |
| `pattern` | Business Semantics | Behavior pattern / flagging rule |
| `derived_metric` | Business Semantics | Calculated metric with formula |
| `threshold` | Business Semantics | Benchmark or percentile limit |

**Relationship Types (Edges):**

| Relationship | From → To | Description |
|--------------|-----------|-------------|
| `BELONGS_TO` | data_field → data_source | Field belongs to table |
| `MAPPED_TO` | metric → data_field | Metric maps to column |
| `MEASURED_BY` | concept → metric | Concept measured by metric |
| `APPLIES_TO` | metric → team | Metric relevant for team |
| `HAS_CONCEPT` | team → concept | Team cares about concept |
| `TRIGGERS` | metric → pattern | Metric can trigger pattern |
| `DERIVED_FROM` | derived_metric → metric | Formula dependencies |
| `DEPENDS_ON` | dbt_model → dbt_model | dbt model dependencies |

### Discovery Engine

Automated system for detecting and onboarding new data fields. When a new column appears in the Metrics Layer, Discovery Engine enriches it with technical metadata and generates AI-powered business semantics.

#### Discovery Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                     DISCOVERY ENGINE                             │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  1. DETECT NEW FIELD                                      │   │
│  │     • Periodic sync with Data Catalog                     │   │
│  │     • Compare known fields vs catalog fields              │   │
│  │     • Flag new/changed columns for processing             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  2. PULL TECHNICAL METADATA (from Metrics Layer)          │   │
│  │     • Column name, data type, nullable                    │   │
│  │     • Table context (which mart, what joins)              │   │
│  │     • dbt model info (description, tests, tags)           │   │
│  │     • Transformation lineage (source → staging → mart)    │   │
│  │     • Sample values and statistics (min, max, distinct)   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  3. ANALYZE CONTEXT (related fields)                       │   │
│  │     • Find similar fields by name pattern                 │   │
│  │     • Look up existing metrics in same category           │   │
│  │     • Identify related concepts and teams                 │   │
│  │     • Check if field correlates with known patterns       │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  4. AI-GENERATE BUSINESS SEMANTICS                         │   │
│  │     • Display name (human-readable)                        │   │
│  │     • Description (what this metric measures)              │   │
│  │     • Category (code, communication, project, etc.)        │   │
│  │     • Aggregation type (SUM, AVG, COUNT, MAX)              │   │
│  │     • Format pattern (number, percentage, duration)        │   │
│  │     • Suggested concepts (Code Quality, Velocity, etc.)    │   │
│  │     • Applicable teams (Dev-Backend, QA, etc.)             │   │
│  │     • Confidence score (how certain AI is)                 │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  5. QUEUE FOR REVIEW                                       │   │
│  │     • High confidence (>90%) → Priority review queue       │   │
│  │     • Medium confidence → Standard review queue            │   │
│  │     • Low confidence → Flag for data engineer input        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  6. HUMAN REVIEW & ACTIVATION                              │   │
│  │     • Analyst reviews AI suggestion                        │   │
│  │     • Edit or approve as-is                                │   │
│  │     • Activate → metric appears in Business Semantics      │   │
│  │     • Reject → field marked as "not a metric"              │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

#### Technical Metadata from Metrics Layer

When a new field is detected, Discovery Engine pulls the following from Data Catalog:

| Metadata | Source | Example |
|----------|--------|---------|
| Column name | information_schema | `loc__added` |
| Data type | information_schema | `Int64` |
| Table name | information_schema | `dev_summary_pivot` |
| dbt model | dbt manifest | `mart_developer_metrics` |
| dbt description | dbt schema.yml | "Lines of code added" |
| dbt tests | dbt manifest | `not_null`, `positive` |
| Upstream sources | dbt lineage | `stg_gitlab_commits` |
| Sample values | ClickHouse query | `[0, 15, 142, 2500]` |
| Statistics | ClickHouse query | `min=0, max=50000, avg=340` |
| Null ratio | ClickHouse query | `2.3%` |

#### AI Context for Generation

AI receives the following context to generate accurate business semantics:

```json
{
  "new_field": {
    "name": "loc__added",
    "type": "Int64",
    "table": "dev_summary_pivot",
    "dbt_description": "Lines of code added in commits",
    "sample_values": [0, 15, 142, 2500, 8400],
    "statistics": { "min": 0, "max": 50000, "avg": 340, "median": 85 }
  },
  "related_fields": [
    { "name": "loc__deleted", "display_name": "LOC Deleted", "category": "code" },
    { "name": "commits", "display_name": "Commits", "category": "code" }
  ],
  "table_context": {
    "name": "dev_summary_pivot",
    "purpose": "Developer activity metrics aggregated by person and period",
    "row_count": 15000
  },
  "existing_concepts": ["Code Output", "Code Quality", "Delivery Velocity"],
  "existing_teams": ["Dev-Backend", "Dev-Frontend", "Dev-Android", "QA"]
}
```

#### AI-Generated Suggestion Example

```json
{
  "field": "loc__added",
  "suggestion": {
    "display_name": "LOC Added",
    "description": "Total lines of code added across all commits. Measures code output volume.",
    "category": "code",
    "aggregation_type": "SUM",
    "format_pattern": "#,##0",
    "suggested_concepts": ["Code Output"],
    "applicable_teams": ["Dev-Backend", "Dev-Frontend", "Dev-Android"],
    "confidence": 0.95,
    "reasoning": "Field name pattern 'loc__added' matches existing 'loc__deleted'. dbt description confirms this is lines of code. SUM aggregation appropriate for cumulative metric."
  }
}
```

#### Review Queue Management

All new metrics require human approval. Confidence score determines priority and reviewer assignment:

| Confidence | Priority | Reviewer | SLA |
|------------|----------|----------|-----|
| **High (>90%)** | Priority queue | Analyst | 4 hours |
| **Medium (70-90%)** | Standard queue | Analyst | 24 hours |
| **Low (<70%)** | Escalation queue | Data Engineer + Analyst | 48 hours |
| **Unknown pattern** | Investigation queue | Data Engineer | 1 week |

**No code deployment needed** — approved metrics appear immediately in Business Semantics and become available for dashboards, AI queries, and pattern matching.

### AI Layer (MCP Servers)

AI Agent uses MCP-tools (Model Context Protocol) which always consult the Semantic Layer first:

- **MCP Tool #1 (Query Data)**: Consults knowledge graph, generates SQL, retrieves from Data View
- **MCP Tool #2 (Visualization)**: Configures and creates visualizations based on user requests
- **MCP Tool #3 (Insights)**: Generates contextual insights using team concepts and patterns

**Dynamic Query Builder:**

The system generates SQL queries dynamically from the knowledge graph:

1. Identifies relevant `data_source` entities
2. Follows `BELONGS_TO` relationships to find `data_field` entities
3. Applies aggregation rules from field properties
4. Filters by team context via `APPLIES_TO` relationships
5. Executes flagging patterns via `TRIGGERS` relationships

This enables fully dynamic analytics without hardcoded SQL.

### Static Data Analyzer

Collection of "hand-picked" (verified) SQL scripts and metrics:

- Fixed, validated formulas and reports (e.g., "Quarterly Activity", "Team Velocity")
- Agent checks here before generating new code
- Provides the path from ad-hoc AI exploration to verified analytics

### Output Layer

User-facing interfaces for data consumption:

- **BI Dashboards**: Interactive visualizations with drill-down
- **Chat UI**: Conversational interface for AI-powered exploration
- **Alerts & Reports**: Scheduled and triggered notifications
- **Export**: Data export in various formats (CSV, Excel, API)

#### Dashboard Taxonomy (3+1 Types)

All dashboards in the platform fall into one of four standard types:

| Type | Audience | Scope | Description |
|------|----------|-------|-------------|
| **Team Dashboard** | Engineering/functional managers | Single team or squad | Tracks team-level metrics — velocity, communication load, quality signals. The manager's primary view. |
| **Individual Dashboard** | Individual contributors | Self (own data only) | Personal productivity self-service view. Individuals can see their own metrics without manager mediation. |
| **Company / Portfolio Dashboard** | Executives, portfolio owners | Full org or multi-company | Org-wide rollup view. Enables cross-team and cross-company benchmarking. |
| **Custom Dashboard** | Analysts, power users | User-defined | Metric combinations and filters defined by the user. Saved views for recurring reporting needs. |

---

## Layer Separation Benefits

| Benefit | Description |
|---------|-------------|
| **Independent Scaling** | Metrics Layer can handle more data sources without affecting Analytics |
| **Multiple Consumers** | One Metrics Layer can serve multiple Analytics instances (Corporate, Education) |
| **Clear Ownership** | Data engineering owns Metrics Layer, Product/Analytics owns Analytics Layer |
| **Technology Flexibility** | Each layer can evolve independently (e.g., swap ClickHouse for another DB) |
| **Deployment Independence** | Update dashboards without touching data pipelines |

## Core Capabilities

### 1. Semantic Unification

Connectors and unifiers normalize heterogeneous systems into shared entities:

```yaml
# Example: Unified Fact Schema
schema:
  person_id: String        # Resolved Identity (from Identity Layer)
  source_id: String        # Original ID in source system
  source_type: String      # Origin system
  category: String         # Activity Type
  value: JSON              # Metric Value
  dimensions: JSON         # Context
  created_at: DateTime     # Temporal Marker
```

### 2. Governed Analytics

Every metric has a definition, formula, and lineage that can be audited:

```yaml
# Example: Metric Definition
metric:
  name: communication_load
  formula: email_sent + email_received + zulip_messages + meetings_interacted
  description: Overall communication activity signal
  lineage:
    upstream: [m365_reports, zulip_messages]
    downstream: [coordination_overhead_alert, person_pulse_dashboard]
```

### 3. AI Within Constraints

AI can only query and visualize within the semantic dictionary and verified analytics:

- Queries are generated based on semantic descriptions, not raw SQL
- AI follows the same governance rules as human analysts
- Ad-hoc explorations can be promoted to verified reports

### 4. Actionable Signals (Flagging Patterns)

Alerts highlight anomalies and correlations, prompting investigation rather than automated judgment. Patterns are stored in the Semantic Layer and can be configured without code deployment.

**Pattern Types:**

| Type | Description | Example |
|------|-------------|---------|
| `negative` | Potential problem requiring attention | Low output, high meetings |
| `positive` | Recognition of good performance | Top contributor, high velocity |
| `neutral` | Informational observation | Role change, new team member |

**Example Patterns:**

- **Burnout Warning**: Late-night activity + high communication + upward task complexity trend
- **Churn Risk**: Sudden drop in activity vs 14-day baseline
- **Coordination Overhead**: High communication-to-tasks ratio indicates sync-tax
- **Gold Plating**: Excessive LOC without corresponding task completion
- **Silent Contributor**: High code output but low visibility (few meetings/messages)

**Pattern Configuration:**
```json
{
  "type": "percentile",
  "conditions": [
    {"metric": "loc_added", "operator": "<=", "threshold": 20},
    {"metric": "meetings_interacted", "operator": ">=", "threshold": 80}
  ],
  "applies_to": ["Dev-Backend", "Dev-Frontend"]
}
```

## Data Sources & Coverage

Insight is domain-agnostic by design. Any dataset can be integrated with a connector and semantic description.

### Currently Integrated Sources (Phase 1: Constructor)

Active integrations for the initial deployment at Constructor (~300 employees):

| Category | Source | Status | Est. Events/Employee/Year |
|----------|--------|--------|---------------------------|
| Communication | Microsoft 365 (Email, Calendar) | Active | ~5,000 |
| Communication | Zulip | Active | ~3,000 |
| Development | GitLab | Active | ~2,500 |
| Development | MCP (AI Assistant) | Active | ~1,000 |
| HR & Organization | BambooHR | Active | ~50 |
| Presence | Office Attendance | Active | ~500 |
| Project Management | YouTrack | Active | ~5,000 |
| **Total** | **7 sources** | | **~17,000/year** |

### Planned Integrations

**Near-term (Phase 2 - Portfolio Expansion):**

| Source | Target Use Case | Target Company | Est. Additional Events/Year |
|--------|-----------------|----------------|----------------------------|
| Bitbucket | PR analytics, reviewer metrics | Acronis | +500 |
| Confluence | Wiki pages, comments, knowledge base | All portfolio companies | +1,000 |
| Jira | Project management (alternative to YouTrack) | Virtuozzo | ~5,000 (replaces YouTrack) |
| Workday | Enterprise HR system | Acronis | ~50 (replaces BambooHR) |

**Mid-term (Phase 3 - Education Segment):**

| Source | Target Use Case | Est. Events/Student/Year |
|--------|-----------------|--------------------------|
| Canvas LMS | Learning activity, assignments, grades | ~5,000 |
| Constructor Platform | Course progress, engagement metrics | ~2,000 |

**Long-term (Future Enhancements):**

| Source | Target Use Case | Est. Additional Events/Year |
|--------|-----------------|----------------------------|
| Active Directory | Authentication events, access logs | +100 |
| Allure | Test results & coverage | +200 (QA roles only) |
| Cursor AI | Direct IDE telemetry (beyond MCP) | +1,000 |
| GitHub | External repositories (open-source contributions) | +500 |
| HubSpot | Sales/Marketing metrics | +300 (sales roles only) |

**Notes:**
- Event counts are **conservative estimates** based on typical usage patterns
- Actual volumes may vary by role (developers generate more code events, managers more communication events)
- Some sources are **alternatives** (Jira vs YouTrack, Workday vs BambooHR) — only one per category active per company
- Education segment (students) has different activity patterns with lower event density than employees

## People Grouping & Access

Insight separates access control from analytical cohorts:

### Org Structure (Access Control)

- Determines visibility and access permissions
- Manager sees their reports, not other teams
- Hierarchical: Company → Division → Department → Team → Person

### Functional Teams (Analytical Cohorts)

- Defines stable cohorts for apples-to-apples comparisons
- Developer vs Developer, Tester vs Tester
- Enables accurate benchmarking across organizational boundaries
- More stable than org structure (people don't frequently switch roles)

This separation enables accurate benchmarking without violating permissions.

### Business Concepts

Concepts link business domains to metrics and teams, enabling contextual analytics:

| Concept | Description | Relevant Teams |
|---------|-------------|----------------|
| Code Quality | Maintainability, technical debt | Dev-Backend, Dev-Frontend |
| Communication Load | Meeting and messaging activity | All teams |
| Delivery Velocity | Task throughput and completion | Development teams |
| Collaboration | Cross-team interactions | All teams |

**How Concepts Work:**
- Each team declares which concepts matter to them (`HAS_CONCEPT`)
- Each concept is measured by specific metrics (`MEASURED_BY`)
- AI uses concepts to generate team-relevant insights
- Same metric can mean different things for different team types

## Identity Resolution Layer

A dedicated layer that resolves and merges identities across all connected systems. This layer operates independently from any specific HR system and can work with any combination of identity sources.

### How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    IDENTITY RESOLUTION LAYER                     │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                   Canonical Person Record                  │  │
│  │     person_id: "p_12345" (system-generated UUID)          │  │
│  │     display_name: "John Doe"                              │  │
│  │     status: active                                        │  │
│  └───────────────────────────────────────────────────────────┘  │
│                             ▲                                    │
│                             │                                    │
│  ┌──────────────────────────┴───────────────────────────────┐   │
│  │                    Identity Mappings                      │   │
│  │  ┌─────────────┬─────────────┬─────────────┬──────────┐  │   │
│  │  │ email       │ git_author  │ jira_user   │ hr_id    │  │   │
│  │  │ john@co.com │ john.doe    │ jdoe        │ EMP-123  │  │   │
│  │  │ j.doe@co.io │             │             │          │  │   │
│  │  └─────────────┴─────────────┴─────────────┴──────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                             ▲                                    │
│           ┌─────────────────┼─────────────────┐                  │
│           │                 │                 │                  │
│     Git commits        Jira/YouTrack      M365/Zulip             │
│     (author email)     (user accounts)    (email/UPN)            │
└─────────────────────────────────────────────────────────────────┘
```

### Key Principles

1. **System-Agnostic**: No dependency on any specific HR system as "source of truth"
2. **Multi-Alias Support**: One person can have multiple emails, usernames, accounts
3. **Merge Rules**: Configurable rules for automatic and manual identity matching
4. **Audit Trail**: All identity merges and splits are tracked
5. **Unmapped Handling**: Unknown identities are flagged for manual resolution

### Identity Matching Strategies

| Strategy | Description | Example |
|----------|-------------|---------|
| **Email Normalization** | Normalize and match by email domain patterns | `john@corp.com` = `john@corp.io` |
| **Name Matching** | Fuzzy match on display names | "John Doe" ≈ "J. Doe" |
| **HR Import** | Bulk import from HR system as baseline | BambooHR, Workday export |
| **Manual Override** | Admin UI for edge cases and corrections | Merge/split person records |
| **Auto-Suggest** | AI suggests potential matches for review | Similar patterns flagged |

### Handling Edge Cases

- **Multiple Emails**: Same person with work + personal email → merged
- **Name Changes**: Marriage, legal changes → alias added, history preserved  
- **Contractors**: External contributors → separate "external" flag
- **Bots/System Accounts**: Filtered or categorized separately
- **Unknown Authors**: Quarantine queue for manual mapping

## Metrics Catalog

### Development & AI

| Metric | Description | Aggregation |
|--------|-------------|-------------|
| `mcp__lines_added` | Code growth via AI | SUM |
| `mcp__task_complexity` | Cognitive load (1-3 scale) | AVG |
| `loc` | Lines Added/Deleted per file | SUM(a+d) |

### Project Management

| Metric | Description | Aggregation |
|--------|-------------|-------------|
| `task__open` / `task__done` | Task lifecycle | SUM |
| `bug__open` / `bug__done` | Defect lifecycle | SUM |
| `user_story__open` / `user_story__done` | Feature lifecycle | SUM |

### Communication

| Metric | Description | Aggregation |
|--------|-------------|-------------|
| `m365_send` / `m365_receive` | Email activity | SUM |
| `m365_interacted` | Meeting participation | SUM |
| `zulip_sent` | Chat messages | SUM |

### Derived Metrics (Examples)

| Metric | Formula | Meaning |
|--------|---------|---------|
| AI Leverage Factor | `ai_loc / (ai_loc + git_loc)` | AI adoption rate |
| Stability Index | `bugs_done / bugs_open` | >1 improving, <1 debt growing |
| Communication Load | `(emails + messages) / tasks_done` | Coordination overhead |

## User Scenarios

### Scenario 1: Executive Company Pulse

An executive opens Insight before a leadership meeting. The dashboard shows:
- Active headcount and communication load
- Velocity trends with highlighted alert for sustained drop in one business unit

The executive asks: *"What changed in the last six weeks?"*

Insight returns:
- Breakdown by functional teams
- Reduced task throughput and coordination overhead spike
- Links to metric definitions and lineage

### Scenario 2: Portfolio Benchmarking

A portfolio owner compares two companies across the same semantic metrics. Insight:
- Normalizes data from different tool stacks into common schema
- Enables credible cross-company benchmarking
- Saves comparison as verified report for quarterly reviews

### Scenario 3: At-Risk Student Identification

A university program director reviews cohort health after adopting Constructor. Insight:
- Flags at-risk subgroup based on engagement and completion patterns
- Shows transparent list of signals and thresholds
- Enables intervention assignment and recovery tracking

### Scenario 4: AI-to-Verified Promotion

An analyst receives a request for a new metric:
1. Explores data using AI interface
2. Validates the result
3. Promotes analysis into Static Analyzer
4. Metric becomes reusable, governed report

## Differentiation vs Traditional BI

| Traditional BI | Insight |
|----------------|---------|
| Visualizes data | Enforces shared meaning first |
| Schema-on-read chaos | Governed semantic dictionary |
| Dashboards only | Dashboards + AI exploration + chat |
| Manual lineage tracking | Automatic data lineage |
| Ad-hoc queries | Verified analytics with promotion path |
| Role-blind comparisons | Functional team-aware benchmarking |

## Product Principles (Non-Negotiable)

1. **Meaning is defined once and reused everywhere**
2. **Every metric is traceable with lineage and formulas**
3. **AI follows the same rules as analysts**
4. **Insights must be explainable and auditable**
5. **The system prioritizes trust over novelty**
6. **Full transparency in all calculations and sources**
7. **Recommendations, not automated judgments**
8. **Productivity metrics must always be paired with quality signals.** Optimizing productivity in isolation — without quality gates — produces vanity metrics, not meaningful insight. High commit volume with low test coverage is a negative signal, not a positive one. Every productivity metric in the platform should have a corresponding quality counterpart or be clearly annotated when quality data is unavailable.

## Implementation Phases

### Phase 1: Metrics-First Validation (Constructor)

Focus on proving semantic governance on internal data:

- **Sources**: Git, YouTrack, Zulip, M365, Office Attendance + HR (BambooHR)
- **Goal**: Prove AI-agent correctly generates SQL from semantic descriptions
- **Visualization**: Custom React dashboards
- **Outcome**: Working prototype on Constructor's ~300 employees

### Phase 2: Portfolio Expansion (Virtuozzo, Acronis)

Normalize additional companies into the same semantic model:

- **Virtuozzo**: Jira for project management
- **Acronis**: Jira, Workday, Bitbucket for global productivity
- **Goal**: Cross-company benchmarking with unified definitions

### Phase 3: Education Scale (Universities, LPE)

Apply same foundation to learning and engagement data:

- **Integrations**: Canvas LMS, Constructor platform, LTI standards
- **Metrics**: Learning activity, outcomes, engagement signals
- **Goal**: At-risk identification and intervention tracking

## Technical Stack

### Metrics Layer Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Storage | **ClickHouse** | Columnar analytics database, high-performance |
| Transformations | **dbt** | Data modeling and transformation pipelines |
| Orchestration | **Airflow / Dagster** | Pipeline scheduling and monitoring |
| Connectors | **Python / Node.js** | Custom adapters for each data source |
| Identity Resolution | **ClickHouse + custom logic** | Person matching and alias management |
| Data Catalog | **dbt docs + custom metadata store** | Table/column registry, lineage tracking |
| API | **Node.js/Express** | Data access + metadata sync for Analytics |

**Storage Technology Selection:** ClickHouse was chosen as the analytical storage after evaluating ClickHouse, MariaDB ColumnStore, and PostgreSQL + TimescaleDB. Key decision factors include native incremental materialized views, first-class JSON support, and proven performance on analytical workloads. 

📄 **Full technical evaluation:** See [STORAGE_TECHNOLOGY_EVALUATION.md](./STORAGE_TECHNOLOGY_EVALUATION.md) for detailed analysis, benchmarks, and risk assessment.

### Analytics Layer Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Frontend | **React 18** + TypeScript + Vite | User interface |
| Styling | **Tailwind CSS** | Component styling |
| Visualizations | **D3.js / Recharts** | Charts and graphs |
| Icons | **Lucide React** | UI icons |
| Backend API | **Node.js/Express** | Analytics endpoints |
| Knowledge Graph | **Custom tables** | Semantic Layer storage |
| AI Orchestration | **MCP Protocol** | AI tool management |
| LLM | **Claude / GPT** | Query generation, insights |
| Config | **Semantic YAML** | Human-editable definitions |

---

## Non-Functional Requirements

### Mobile Accessibility

Dashboards must be accessible on mobile devices. Metrics should be available to employees at any time, without requiring access to a desktop workstation. Key requirements:

- All dashboard types (Team, Individual, Company, Custom) must render correctly on mobile screen sizes
- Individual and Team dashboards are the primary mobile use cases — employees and managers checking their metrics on the go
- Read-only mobile experience is the minimum requirement; complex configuration (custom dashboards, semantic dictionary editing) may be desktop-only
- Push notifications for alerts and anomaly signals must support mobile delivery

---

## Success Criteria

| Metric | Target |
|--------|--------|
| Time-to-insight | Hours → Minutes |
| KPI adoption | Standardized metrics used by leadership |
| Cross-company benchmarks | Trusted comparisons across portfolio |
| AI → Verified promotion | Regular conversion of explorations to reports |
| At-risk detection (education) | Measurable reduction in undetected cohorts |
| Intervention outcomes | Improved recovery rates |

## Planned Features & Open Questions

### Cross-Company Anonymous Benchmarking

**Status**: Planned — requires anonymization pipeline and multi-workspace aggregation design.

**Description**: Future capability to aggregate anonymized metrics across workspaces and enable cross-company benchmarking. Example: "Your team's AI tool adoption rate is in the top 20% of similar-size engineering teams across the platform."

**Value**: Organizations can contextualize their own metrics against industry peers without exposing raw data. Portfolio owners can benchmark portfolio companies against external baselines.

**Open Design Questions**:
- Anonymization pipeline: how to aggregate metrics without exposing individual workspace identity
- Multi-workspace aggregation: extending the current single-workspace data model to a federated or centralized aggregate store
- Opt-in/opt-out mechanics: workspace administrators must explicitly consent to participation
- Statistical minimums: prevent re-identification when a metric is based on very few workspaces (e.g., minimum N=5 workspaces per benchmark bucket)
- GDPR/data residency: aggregated data must comply with the most restrictive jurisdiction among participating workspaces

---

## Appendix: Key Terminology

### Product Layers

| Term | Definition |
|------|------------|
| **Metrics Layer** | Product layer responsible for data collection, normalization, and storage |
| **Analytics Layer** | Product layer responsible for semantic governance, AI analysis, and visualization |

### Metrics Layer Terms

| Term | Definition |
|------|------------|
| **Connector** | Plugin that fetches data from a specific source system |
| **Unifier** | Component that normalizes disparate systems into unified schema |
| **Data Catalog** | Central registry of tables, columns, dbt models, and transformation lineage |
| **dbt Model** | Transformation definition with SQL, tests, and documentation |
| **Transformation Lineage** | Graph of dependencies from source to mart |
| **Identity Resolution Layer** | Dedicated layer that merges identities from all connected systems |
| **Canonical Person** | Unified person record with all platform-specific IDs mapped to it |
| **Data Mart** | Pre-aggregated view optimized for analytical queries |

### Analytics Layer Terms

| Term | Definition |
|------|------------|
| **Business Semantics** | Knowledge graph adding business meaning to Data Catalog metadata |
| **Knowledge Entity** | Node in the semantic graph (metric, team, pattern, concept) |
| **Knowledge Relationship** | Edge connecting entities (MAPPED_TO, APPLIES_TO, etc.) |
| **Discovery Engine** | Syncs Data Catalog and suggests business semantics for new fields |
| **Metric** | Business measurement mapped to data fields with display rules |
| **Concept** | Business domain area linking metrics to teams |
| **Pattern** | Flagging rule that triggers alerts based on metric conditions |
| **Derived Metric** | Calculated metric with formula referencing other metrics |
| **Static Analyzer** | Collection of verified, curated SQL scripts and reports |
| **Functional Team** | Stable cohort for analytics (Developer, Tester, etc.) |
| **Data Lineage** | Full traceability from raw source to final metric (spans both layers) |
| **MCP** | Model Context Protocol for AI tool orchestration |

---

*This specification consolidates product architecture, data flows, and implementation details from meeting notes, strategy documents, and technical specifications across the Insight project workspace.*

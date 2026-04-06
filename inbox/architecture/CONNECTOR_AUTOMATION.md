# Connector Automation: What Can Be Generated and What Cannot

> Version 1.0 — March 2026

---

## Table of Contents

- [1. Why Full Automation Is Not Possible](#1-why-full-automation-is-not-possible)
- [2. The Bronze/Silver Boundary Is the Automation Boundary](#2-the-bronzesilver-boundary-is-the-automation-boundary)
  - [2.1 Why Bronze is largely automatable](#21-why-bronze-is-largely-automatable)
  - [2.2 Why Silver cannot be automated — three reasons](#22-why-silver-cannot-be-automated--three-reasons)
  - [2.3 Summary: what each layer requires](#23-summary-what-each-layer-requires)
- [3. What CAN Be Automated](#3-what-can-be-automated)
  - [3.1 Boilerplate Structure](#31-boilerplate-structure)
  - [3.2 Standard Metadata Columns](#32-standard-metadata-columns)
  - [3.3 Authentication Flows](#33-authentication-flows)
  - [3.4 Pagination](#34-pagination)
  - [3.5 Incremental Sync Cursor](#35-incremental-sync-cursor)
  - [3.6 Rate Limiting](#36-rate-limiting)
  - [3.7 Field Type Inference (Partial)](#37-field-type-inference-partial)
  - [3.8 Bronze Table DDL Generation](#38-bronze-table-ddl-generation)
- [4. What CANNOT Be Automated](#4-what-cannot-be-automated)
  - [4.1 Custom Field Names Per Instance](#41-custom-field-names-per-instance)
  - [4.2 Derived Fields Requiring Business Logic](#42-derived-fields-requiring-business-logic)
  - [4.3 Multi-Step Collection (Associations and Linked Objects)](#43-multi-step-collection-associations-and-linked-objects)
  - [4.4 Unit Normalisation Across Sources](#44-unit-normalisation-across-sources)
  - [4.5 Status and Enum Normalisation](#45-status-and-enum-normalisation)
  - [4.6 Identity Resolution Rules](#46-identity-resolution-rules)
  - [4.7 Data Retention Windows and Collection Frequency Constraints](#47-data-retention-windows-and-collection-frequency-constraints)
  - [4.8 Privacy and Content Collection Decisions](#48-privacy-and-content-collection-decisions)
  - [4.9 Multi-Instance Disambiguation](#49-multi-instance-disambiguation)
  - [4.10 Self-Hosted and Version-Specific API Differences](#410-self-hosted-and-version-specific-api-differences)
  - [4.11 Silver Mapping Semantics](#411-silver-mapping-semantics)
- [5. The Automation Boundary — A Mental Model](#5-the-automation-boundary--a-mental-model)
- [6. What This Means for the Connector SDK](#6-what-this-means-for-the-connector-sdk)
- [7. AI-Assisted Silver Layer Mapping](#7-ai-assisted-silver-layer-mapping)
  - [7.1 What the AI analyses](#71-what-the-ai-analyses)
  - [7.2 What the AI proposes](#72-what-the-ai-proposes)
  - [7.3 The Connector Onboarding UI](#73-the-connector-onboarding-ui)
  - [7.4 Creating new Silver classes](#74-creating-new-silver-classes)
  - [7.5 What remains manual even with AI assistance](#75-what-remains-manual-even-with-ai-assistance)

---

## 1. Why Full Automation Is Not Possible

The appeal of full connector automation is obvious: every connector on the Insight platform follows the same structural pattern — authenticate, paginate, collect, write to Bronze, log the run. If the pattern is uniform, why not generate the entire connector from an API schema?

The answer is that structural uniformity ends at the API boundary. Below it, every source system has been built by a different vendor, for a different purpose, with different data models and different business vocabularies. The connector's job is not merely to retrieve data — it is to retrieve *the right data*, represent it *correctly*, and make it *analytically useful* for employees whose work it will describe. That last requirement cannot be satisfied by inspecting an OpenAPI schema.

Three categories of problem make full automation impossible.

**API heterogeneity.** Authentication varies across systems — BambooHR uses an API key header, Zulip uses HTTP Basic Auth over a per-realm endpoint, M365 requires OAuth 2.0 with tenant-scoped tokens. Pagination is inconsistent — YouTrack uses `$skip/$top` offset parameters, Jira uses `startAt/maxResults`, HubSpot uses a cursor token returned in the response body, and M365 activity reports simply return the full dataset for a declared period. Rate limits range from well-documented (HubSpot: 100 calls per 10 seconds per app) to undocumented or version-dependent. None of this is impossible to handle, but each variation must be declared or implemented per connector.

**Instance-level configuration.** The same SaaS product installed at two different customers is effectively two different systems. A YouTrack instance at one organisation names the story points field `Story Points`; at another it is `Estimation`; at a third it is `SP`. A Jira instance using Classic projects stores story points in a fixed field; one using Next-gen projects stores them in `customfield_10016`. HubSpot deal stages are entirely portal-specific — `appointmentscheduled` at one customer, `demo_scheduled` at another. No OpenAPI schema describes these variations because they are not part of the schema; they are runtime configuration choices made by each organisation's administrator.

**Semantic judgment.** The most important decisions in connector design are not technical — they are analytical. Is `hs_call_disposition` a useful field? Not in isolation, because it returns a GUID, not a label. Should Zulip message text be collected? No, because Insight's privacy policy does not permit storage of individual message content. Do HubSpot contacts represent internal employees? No, they represent external customers — resolving them to `person_id` would be wrong. Does a YouTrack state transition from `In Progress` to `Resolved` mean the same thing analytically as a Jira transition from `In Progress` to `Done`? Yes — but only a human who understands both systems and the Silver layer's purpose can confirm that equivalence.

A connector that automates the structural mechanics while leaving the semantic layer unaddressed would collect data faithfully and produce nothing useful. The Bronze tables would fill up; the Silver layer would contain no meaningful mappings; the Gold layer would have no metrics to serve. Full automation would not create a connector — it would create a data dump with correct timestamps.

The practical conclusion is not that the semantic layer is off-limits to tooling — it is that the semantic layer cannot be *skipped*. AI can draft Silver mapping proposals, suggest enum normalisation, and surface identity key candidates by analysing Bronze data after it has been collected. But those proposals require a human to review, confirm, and override. The authorship is not eliminated; the blank-page problem is. This distinction is the foundation of the AI-assisted onboarding approach described in §7.

---

## 2. The Bronze/Silver Boundary Is the Automation Boundary

The clearest way to understand the automation limit is to map it against the medallion layers.

**The automation boundary maps almost exactly to the Bronze/Silver boundary. Bronze is a structural problem — it can be largely generated. Silver is a semantic problem — it requires authorship.**

```
┌─────────────────────────────────────────────────────────────────┐
│  BRONZE LAYER                                     ✅ Automatable │
│                                                                  │
│  "Collect what the API returns, store it faithfully."            │
│                                                                  │
│  • Which endpoints to call          → declared in connector.yaml │
│  • Auth, pagination, rate limiting  → framework                  │
│  • Schema follows from API response → generated from field list  │
│  • Metadata columns                 → framework-injected         │
│  • Custom fields go to _ext table   → generated on declaration   │
│  • collection_runs monitoring       → 100% generated             │
│                                                                  │
│  Manual work remaining at Bronze: decide which endpoints to      │
│  call, which fields to keep, how to handle structural quirks     │
│  (multi-step calls, associations). Business logic: none yet.     │
└──────────────────────────┬──────────────────────────────────────┘
                           │  Bronze data in ClickHouse
            ╔══════════════╪══════════════╗
            ║  AUTOMATION  │  BOUNDARY    ║
            ╚══════════════╪══════════════╝
                           │
                    ┌──────▼───────┐
                    │  AI ANALYSIS │  🤖 reads Bronze, drafts proposals
                    │              │  • field → Silver column candidates
                    │              │  • enum normalisation suggestions
                    │              │  • unit conversion detection
                    │              │  • custom field promotion advice
                    │              │  • identity key candidates
                    └──────┬───────┘
                           │  proposals (not applied automatically)
                    ┌──────▼───────┐
                    │  ONBOARDING  │  👤 human reviews, approves, overrides
                    │     UI       │  • approve / reject each mapping
                    │              │  • fix enum mappings manually
                    │              │  • confirm identity rules
                    │              │  • define new Silver class if needed
                    └──────┬───────┘
                           │  approved semantic contract
┌──────────────────────────▼──────────────────────────────────────┐
│  SILVER LAYER                              ❌ Cannot be automated │
│                                                                  │
│  "Make data from different sources mean the same thing."         │
│                                                                  │
│  Step 1: Unification        Step 2: Identity      Custom fields  │
│  (cross-source normalise)   (Resolution)          (promotion)    │
│                                                                  │
│  🤖→👤 Enum equivalence      🤖→👤 Key candidates   🤖→👤 Str/num  │
│  🤖→👤 Unit normalisation    ❌  Privacy decisions  ❌  New class? │
│  ❌  Derived fields          ❌  Fallback strategy               │
│  ❌  Internal vs external                                        │
│                                                                  │
│  🤖→👤 = AI drafts, human approves    ❌ = human only            │
└─────────────────────────────────────────────────────────────────┘
```

### 2.1 Why Bronze is largely automatable

Bronze has one job: retrieve data from a source API and write it to ClickHouse without losing or altering it. This is a structural task — it involves authentication, pagination, error handling, and schema definition, but it does not require knowing what the data *means*. A connector author can declare:

- Which endpoints to call and in what order
- Which fields to keep from each response
- Which field is the incremental cursor
- Whether custom fields exist and should go to `_ext`

Everything else — the collection loop, the run log, the deduplication column, the metadata fields — is the same in every connector and can be generated. The Bronze layer's manual residue is thin: endpoint selection, field selection, and structural quirks (associations, multi-step calls) that aren't visible from the API schema alone.

### 2.2 Why Silver cannot be automated — three reasons

**Silver Step 1: Unification**

Silver Step 1 takes raw Bronze tables from multiple sources and normalises them into a single unified class table. This requires deciding that two things from different systems mean the same thing. That decision cannot be automated because:

- **Enum vocabulary is source-specific.** YouTrack issue states are fully configurable per instance — `Resolved`, `Fixed`, `Done`, `Closed` might all mean "work is complete" depending on how a team configured their workflow. Jira has `Done` as a standard final state but projects can add custom states. Salesforce opportunity stages include `Closed Won` and `Closed Lost` as standard values. HubSpot deal stages are entirely portal-specific (`appointmentscheduled`, `closedwon`). There is no algorithm that maps these to a common lifecycle state — only a human who knows the platform and the customer's setup can do so. This is documented explicitly in OQ-CRM-3.

- **Units are source-specific.** The same concept — activity duration — arrives in milliseconds from HubSpot calls (`hs_call_duration`), as a derived difference from HubSpot meetings (`hs_meeting_end_time − hs_meeting_start_time`), in minutes from Salesforce Events (`DurationInMinutes`), in seconds from Salesforce Tasks (`CallDurationInSeconds`), and in minutes from YouTrack worklogs (`duration.minutes`). Silver Step 1 normalises all of these to `duration_seconds`. An automated system reading these field names would have no basis for knowing their units or that they represent the same concept.

- **Some fields in Silver do not exist in Bronze.** `is_won` and `is_closed` in `crm_deals` are not fields returned by the HubSpot Deals API. They must be derived in Silver by fetching pipeline stage settings separately (OQ-CRM-1). Call disposition in `crm_activities` is a GUID in Bronze (`hs_call_disposition`) and a human-readable label in Silver — the resolution requires a separate API call to `GET /crm/v3/objects/call-dispositions`. These derived fields require explicit connector logic; they cannot be inferred from the Bronze schema.

**Silver Step 2: Identity Resolution**

Silver Step 2 enriches unified records with `person_id` by resolving source-specific user identifiers to canonical internal identities. The mechanism (lookup table, email normalisation, fallback chain) can be encoded in a framework. The *rules* cannot:

- Which field is the identity key is source-specific and sometimes ambiguous. In HubSpot, `hubspot_owners.email` identifies internal salespeople and resolves to `person_id`; `hubspot_contacts.email` identifies external customers and must *not* resolve to `person_id`. The API schema does not encode this distinction — it must be declared by the connector author (OQ-HS-1).
- Jira Cloud may suppress `emailAddress` for some users via Atlassian privacy controls. When email is unavailable, the fallback strategy — use `account_id` within the Atlassian ecosystem, exclude the user from person-level analytics, or flag the record — is a product decision that cannot be automated (OQ-JIRA-1).
- Identity key format varies: YouTrack uses `1-234` string IDs, OKTA uses UUIDs, BambooHR uses numeric employee IDs, M365 uses UPN (email format). The connector must declare which field is the cross-system key and what its format is. An earlier spec assumed `UInt64` for YouTrack author IDs — this was wrong because `1-234` is not a valid integer, and the error was only caught during manual review (OQ-YT-2).

**Silver custom field promotion**

The `_ext` key-value tables in Bronze capture every custom field the source exposes. Silver promotes a selected subset of these into `custom_str_attrs Map(String, String)` and `custom_num_attrs Map(String, Float64)` on the unified class tables. Selecting *which* custom fields to promote, what to name the Map keys, and whether a given field is string or numeric requires knowing the customer's business context:

- A YouTrack instance might have 30 custom fields. The ones relevant for analytics might be `Squad`, `Customer`, and `Feature Area`. Promoting all 30 into Silver would produce noise; promoting none would lose important segmentation dimensions.
- Whether a field is string or numeric is not always obvious from its values. A field named `Priority Score` might contain `1`, `2`, `3` (numeric) or `P1`, `P2`, `P3` (string) depending on the instance.
- Map key names (`squad`, `customer`, `feature_area`) must be stable across collection runs — changing a key name breaks all historical queries that use it.

These decisions are made in a per-workspace Custom Attributes Configuration file, not in the connector code. They require a human familiar with both the source system and the analytics use cases.

### 2.3 Summary: what each layer requires

| Layer | Task | Manual residue |
|-------|------|----------------|
| **Bronze** | Collect faithfully | Endpoint selection, field selection, structural quirks (associations, multi-step calls) |
| **Silver Step 1** | Unify across sources | Enum equivalence, unit normalisation, derived fields, semantic mapping |
| **Silver Step 2** | Personalise with `person_id` | Identity rules, fallback strategy, internal vs external user distinction |
| **Silver custom fields** | Promote from `_ext` to Maps | Which fields matter, what to name them, string vs numeric |
| **Gold** | Aggregate for dashboards | Metric definitions, threshold configuration — outside connector scope |

The Gold layer is entirely outside connector scope — it reads from Silver and is authored by analytics engineers, not connector developers.

---

## 3. What CAN Be Automated

### 3.1 Boilerplate Structure

Every connector in the platform requires the same set of scaffolding artifacts: a manifest file, a base class implementation, a collection monitoring table, and (for connectors that handle custom fields) a key-value extension table.

**connector.yaml manifest skeleton.** The manifest declares connector identity, auth type, endpoint list, pagination strategy, and capabilities. Its structure is fully specified by a versioned schema. The SDK can generate a skeleton with all required fields stubbed out, leaving the connector author to fill in source-specific values:

```yaml
connector:
  id: {source}_connector
  name: ""
  version: "1.0.0"
  source_type: ""
  config:
    required_env_vars: []
    optional_env_vars: []
  capabilities:
    incremental_sync: true
    full_refresh: false
    schema_discovery: false
  endpoints: []
```

**base_connector.py inheritance.** Every connector extends the same base class, which provides the collection loop, error handling, cursor management, and run logging. The connector author implements only the source-specific extraction logic.

**`{source}_collection_runs` table.** The collection monitoring table has an identical schema across all connectors in the platform. Comparing `youtrack_collection_runs`, `hubspot_collection_runs`, `jira_collection_runs`, `ms365_collection_runs`, `zulip_collection_runs`, and `bamboohr_collection_runs` reveals a common core: `run_id String`, `started_at DateTime64(3)`, `completed_at DateTime64(3)`, `status String`, `api_calls Float64`, `errors Float64`, `settings String`. The only variation is connector-specific row-count fields (e.g. `issues_collected`, `contacts_collected`). The common core can be 100% generated; the per-entity count fields are additive declarations, not logic. This table is boilerplate and should never be hand-written.

**`{source}_{entity}_ext` key-value table.** Wherever a connector must handle custom fields, it produces a companion extension table. The schema is identical across all eight `_ext` tables in the platform (`youtrack_issue_ext`, `jira_issue_ext`, `hubspot_contact_ext`, `hubspot_deal_ext`, `salesforce_opportunity_ext`, `salesforce_contact_ext`, `bamboohr_employee_ext`, and others):

| Field | Type |
|-------|------|
| `insight_source_id` | String |
| `entity_id` | String |
| `field_id` | String |
| `field_name` | String |
| `field_value` | String |
| `value_type` | String |
| `collected_at` | DateTime64(3) |
| `data_source` | String |
| `_version` | UInt64 |

This schema never varies. Declaring `has_custom_fields: true` in the connector manifest should be sufficient for the SDK to generate the `_ext` table DDL automatically.

---

### 3.2 Standard Metadata Columns

Four columns appear in every Bronze table across the entire connector fleet. They are injected by the base connector framework and are never written by connector authors:

- **`collected_at DateTime64(3)`** — timestamp of the collection run that produced the row. Populated by the base framework at write time.
- **`data_source String`** — the connector's canonical identifier (e.g. `insight_youtrack`, `insight_hubspot`). Populated from the `connector.id` field in the manifest.
- **`insight_source_id String`** — the specific instance being collected from (e.g. `youtrack-acme-prod`, `jira-virtuozzo-prod`). Populated from the connector's runtime configuration.
- **`_version UInt64`** — epoch milliseconds at collection time. Used as the deduplication sort key in ClickHouse ReplacingMergeTree tables.

These columns are structural infrastructure. Any connector that declares them explicitly is doing unnecessary work; the base framework should own them entirely.

---

### 3.3 Authentication Flows

Standard authentication patterns are identical across connectors that share the same auth type. The connector author declares the auth type in `connector.yaml`; the base framework handles all token management:

- **API key header injection**: BambooHR (`Authorization: Basic base64(api_key:x)`), YouTrack (`Authorization: Bearer {token}`). Once the env var name is declared, the framework injects the header on every request.
- **HTTP Basic Auth**: Zulip (`{bot_email}:{api_key}` per realm). Declared in manifest; the framework constructs the auth header.
- **OAuth 2.0 Authorization Code / Connected App**: M365 (tenant-scoped access token with refresh), Salesforce (Connected App OAuth flow). Token lifecycle management — acquisition, refresh, expiry handling — is identical across all OAuth 2.0 sources and belongs in the framework.

The connector author's only responsibility for auth is declaring the type and the env var names for credentials. No auth logic should appear in connector source code.

---

### 3.4 Pagination

Pagination strategies are finite and well-defined. The base framework supports three patterns; the connector declares which one applies:

**Offset/limit pagination** (YouTrack, Jira): The framework issues `GET /api/issues?$skip=0&$top=100`, increments `$skip` by `$top` on each call, and stops when the response contains fewer records than `$top`. The connector declares:

```yaml
pagination:
  type: offset
  skip_param: "$skip"
  limit_param: "$top"
  page_size: 100
```

**Page-token pagination** (HubSpot): Each response contains a `paging.next.after` cursor token. The framework extracts it and appends `&after={token}` to the next request, stopping when `paging.next` is absent. The connector declares `pagination: type: cursor, cursor_path: paging.next.after`.

**Report-period pagination** (M365 Graph API): The API returns the full dataset for a declared period; there is no pagination cursor. The connector declares `pagination: type: none`.

All pagination logic lives in the framework. A connector that implements its own pagination loop is duplicating framework responsibility.

---

### 3.5 Incremental Sync Cursor

For sources that support filtering by last-modified timestamp, the framework can manage the cursor entirely:

1. At run start: read the last successful cursor from the cursor store.
2. Inject the cursor into the API request (e.g. `?updated={cursor}` or `?since={cursor}`).
3. After successful collection: write the new cursor value.
4. On failure: leave the cursor unchanged so the next run retries from the same position.

The connector declares the cursor field:

```yaml
endpoints:
  - name: issues
    cursor_field: updated
    cursor_injection: query_param
    cursor_param: "updatedAfter"
```

Concrete examples: `youtrack_issue.updated` (Unix ms timestamp returned by YouTrack, injected as `?updatedAfter=`), `jira_issue.updated` (ISO 8601 datetime returned by Jira, injected as JQL `updated > "{cursor}"`), `hubspot_deals.hs_lastmodifieddate` (injected via HubSpot filter API). All three follow the same pattern; only the field name and injection format differ.

---

### 3.6 Rate Limiting

Exponential backoff with jitter on 429 and 503 responses is universal. The framework implements it once; connectors declare their rate limit parameters:

```yaml
rate_limiting:
  requests_per_window: 100
  window_seconds: 10
  backoff_initial_ms: 1000
  backoff_max_ms: 60000
  backoff_multiplier: 2.0
```

No connector should contain its own retry logic. If a connector's source has undocumented rate limits (as many self-hosted systems do), the connector declares a conservative default; the framework enforces it.

---

### 3.7 Field Type Inference (Partial)

Simple field types can be inferred from an OpenAPI schema or a sample API response with reasonable accuracy:

| Source type | Inferred ClickHouse type |
|-------------|--------------------------|
| `string` | `String` |
| `integer` (non-negative) | `UInt64` |
| `integer` (signed) | `Int64` |
| `number` (float) | `Float64` |
| `boolean` | `Bool` |
| ISO 8601 datetime string | `DateTime64(3)` |
| Date-only string (`YYYY-MM-DD`) | `Date` |

This covers the majority of fields in any connector's Bronze schema. However, inference fails for all cases that require domain knowledge:

- Unix millisecond timestamps (e.g. YouTrack's `created` field) look like `Int64` but must be converted and typed as `DateTime64(3)`. The conversion logic cannot be inferred from the schema.
- Duration fields in milliseconds (e.g. `hs_call_duration`) look like `Float64` and are typed correctly — but the unit, and the need to convert to seconds at Silver, is invisible to inference.
- ID fields that look like integers but must be typed as `String` (YouTrack's `1-234` format — see OQ-YT-2) cannot be inferred without knowing the format's semantic.

Type inference is an accelerator for the common case, not a replacement for deliberate field-by-field decisions on complex cases.

---

### 3.8 Bronze Table DDL Generation

Given a declared field list with names, types, and constraints, the framework generates the ClickHouse `CREATE TABLE` DDL:

```sql
CREATE TABLE IF NOT EXISTS {source}_{entity}
(
    insight_source_id  String,
    {field_name}        {ClickHouse_type},
    ...
    collected_at        DateTime64(3),
    data_source         String  DEFAULT '',
    _version            UInt64
)
ENGINE = ReplacingMergeTree(_version)
ORDER BY ({primary_key}, insight_source_id)
SETTINGS index_granularity = 8192;
```

The connector author provides the field declarations; the framework generates the DDL. No connector author should be writing `CREATE TABLE` statements by hand.

---

## 4. What CANNOT Be Automated

### 4.1 Custom Field Names Per Instance

**YouTrack story points (OQ-YT-3).** YouTrack stores story point estimates as a custom field. The field name is defined by each organisation's project template. On one YouTrack instance it is `Story Points`; on another it is `Estimation` (with values in minutes, not points); on a third it is `SP`. No OpenAPI schema describes this variation because it is runtime configuration, not API design. The connector must be configured with the correct field name per instance, and the connector author must document that this is an instance-specific setting, not a hard-coded field path.

**Jira story points (OQ-JIRA-3).** Jira Classic projects use a field named `story_points`; Jira Next-gen projects use `customfield_10016`; some enterprise instances have renamed this field entirely. The `jira_projects.style` field (`classic` or `next-gen`) indicates which base convention applies, but the actual custom field ID must be discovered at runtime or manually configured. Auto-detection is possible as a best-effort heuristic but cannot be relied upon — the connector author must verify and document the correct field ID per deployment.

**HubSpot custom contact and deal properties.** HubSpot portals accumulate portal-specific properties with internal names like `hs_lead_status`, `hs_latest_source_timestamp`, or fully custom properties like `customer_segment_hq` created by individual customers. The field names, their analytical relevance, and whether they should be promoted from `hubspot_contact_ext` or `hubspot_deal_ext` to Silver are decisions that require understanding each customer's CRM configuration. No inference over the HubSpot properties API can determine which custom properties matter for a given customer's analytics.

---

### 4.2 Derived Fields Requiring Business Logic

**HubSpot `is_won` / `is_closed` (OQ-CRM-1).** These fields are not returned by the HubSpot Deals API. The Deal response returns only `dealstage`, a portal-specific internal name like `appointmentscheduled` or `closedwon`. Whether a given stage represents a won or lost deal is defined in pipeline settings, not in the deal schema. Derivation requires a separate API call to `GET /crm/v3/pipelines/deals`, fetching each stage's `metadata.isClosed` and `metadata.probability` (probability = 100 means won; probability = 0 means lost). This multi-step, cross-resource logic cannot be inferred from the deal schema and cannot be generated. An automated schema reader sees a `String` field named `dealstage` — nothing in the schema reveals the dependency on pipeline settings. By contrast, Salesforce Opportunities expose `is_closed` and `is_won` as native boolean fields — the same analytical requirement has completely different implementation patterns across the two CRM systems.

**HubSpot meeting duration.** The `duration_ms` field in `hubspot_activities` is `NULL` for meeting records — HubSpot does not return meeting duration directly. Duration must be computed as `hs_meeting_end_time − hs_meeting_start_time`. The field that an analyst needs (`duration_seconds`) does not exist in the API; the fields that allow computing it (`hs_meeting_end_time`, `hs_meeting_start_time`) are not obviously a duration pair from their names alone. This derivation must be manually specified in the connector.

**HubSpot call disposition.** The `hs_call_disposition` field in `hubspot_activities` returns a GUID such as `9d9162e7-6cf3-4944-bf63-4dff82258764`. This GUID is not documented in the API schema and has no meaning to a downstream analyst. A separate call to `GET /crm/v3/objects/call-dispositions` is required to resolve each GUID to its human-readable label (e.g. `Connected`, `Left live message`, `No answer`). No automated schema inspection would identify this dependency — the GUID looks like a standard identifier, not a foreign key into a separate resolution endpoint.

---

### 4.3 Multi-Step Collection (Associations and Linked Objects)

**HubSpot associations.** Relationships between HubSpot objects — contacts to companies, deals to contacts, deals to companies — are not properties on the objects themselves. They are stored in a separate Associations API (`/crm/v3/objects/{objectType}/{id}/associations/{toObjectType}`). The `hubspot_associations` Bronze table exists because of this architectural choice; it has no equivalent in any other connector. No schema inspection of the Contacts, Companies, or Deals endpoints would reveal that a separate table is needed — the association data is structurally absent from the main object responses.

**YouTrack issue history.** The `youtrack_issue_history` table collects every field change ever made to an issue. This data is available from `/api/issues/{id}/activities`, which requires one API call per issue. It is not a nested field in the issue response — it is a separate endpoint that must be explicitly collected in a per-issue loop. The `youtrack_issue_history` table only exists because the connector author made a deliberate design decision to collect it. An automated connector generated from the YouTrack issues endpoint would produce only current state, missing the event log entirely, and making cycle time, status periods, and assignee history impossible to calculate at Gold.

**Jira changelog.** The same pattern applies: `GET /rest/api/3/issue/{key}/changelog` is a separate endpoint, one call per issue. Not represented in the issue schema. The `jira_issue_history` table requires explicit implementation of a per-issue collection loop. Without it, all history-dependent Gold metrics (cycle time, sprint carry-over, status period analysis) are unavailable.

**Zendesk audits.** `GET /api/v2/tickets/{id}/audits` — one call per ticket, separate from the ticket response. The pattern is identical: the event log is structurally absent from the main object and requires a secondary collection pass.

These multi-step patterns represent the most analytically valuable data in each system — they are the source of all time-series and lifecycle metrics. They are also precisely the patterns that no automated schema traversal would discover.

---

### 4.4 Unit Normalisation Across Sources

The same analytical concept — duration of a work activity — is stored in different units depending on the source system and even the activity type within a single system. The Silver layer normalises all durations to seconds (`duration_seconds`), requiring different transformations per source:

| Source | Field | Unit | Transformation |
|--------|-------|------|----------------|
| HubSpot calls | `hs_call_duration` | milliseconds | ÷ 1000 |
| HubSpot meetings | `hs_meeting_end_time − hs_meeting_start_time` | milliseconds | ÷ 1000 |
| Salesforce Events | `DurationInMinutes` | minutes | × 60 |
| Salesforce Tasks (calls) | `CallDurationInSeconds` | seconds | no conversion |
| YouTrack worklogs | `duration.minutes` | minutes | × 60 |
| Jira worklogs | `timeSpentSeconds` | seconds | no conversion |

These unit conventions are not present in any API schema. An OpenAPI definition for `hs_call_duration` describes it as `number` — it does not state the unit. The same is true for `DurationInMinutes` and `duration.minutes`. The connector author must read the source system's developer documentation and explicitly encode the conversion. No inference over field names, types, or sample values can reliably recover unit information.

The consequence of missing or incorrect unit normalisation is a Silver table where `duration_seconds` from HubSpot calls appears to be 1000× larger than from Jira worklogs — a silent data quality failure that would produce incorrect Gold metrics without any error signal.

---

### 4.5 Status and Enum Normalisation

Each source uses its own vocabulary for the same lifecycle concepts. The Silver layer must map these vocabularies to a common set — but the mapping is defined by business logic, not by schema inspection.

**Jira issue status to support ticket status.** For Jira Service Management (JSM) used as a support tool, the connector must map project-specific status names to Insight's canonical support ticket states: `"To Do" → new`, `"In Progress" → open`, `"Waiting for customer" → pending`, `"Done" → solved`. JSM statuses are instance-configurable — a customer can rename `"Waiting for customer"` to `"Pending Client Response"` — and the mapping must be defined per-deployment. There is no status taxonomy in the Jira API schema.

**HubSpot deal stages vs Salesforce deal stages (OQ-CRM-3).** HubSpot portal-specific stage names (`appointmentscheduled`, `closedwon`, `closedlost`) bear no lexical resemblance to Salesforce standard stage names (`Prospecting`, `Closed Won`, `Closed Lost`). A cross-CRM stage funnel analysis requires a normalisation layer that maps both sets to a common taxonomy. OQ-CRM-3 documents that there is no universal stage taxonomy and that the current approach preserves raw stage values in Bronze, deriving only binary `is_won`/`is_closed` in Silver. The decision not to attempt full stage normalisation was a deliberate judgment call — the correct call — made by a connector author who understood both systems.

**YouTrack issue states.** YouTrack state names are fully instance-configurable. A state named `In Review` in one organisation's workflow may not exist in another. Mapping YouTrack states to Insight's canonical task lifecycle events (`open`, `in_progress`, `blocked`, `done`) requires a per-instance configuration, not a static mapping.

---

### 4.6 Identity Resolution Rules

**HubSpot dual user model (OQ-HS-1).** HubSpot contains two distinct user concepts with opposite resolution rules. `hubspot_owners` are internal salespeople — Insight employees whose activity should be attributed to a `person_id`. `hubspot_contacts` are external customers — these are CRM objects, not employees, and should not be resolved to `person_id`. The boundary between these two concepts is not structural: both are stored as records with an `email` field. The connector author must explicitly declare that owners are resolved and contacts are not. OQ-HS-1 documents the edge case where an internal employee appears as a contact — resolving this requires a business logic decision (cross-reference against known internal emails) that no schema reader can make automatically.

**Jira Cloud email suppression (OQ-JIRA-1).** Atlassian privacy controls may suppress `emailAddress` for some users in Jira Cloud responses. The fallback strategy — use `account_id` as an alternative resolution path within the Atlassian ecosystem — requires a deliberate design decision in the Identity Manager. Two approaches are available: exclude suppressed users from person-level analytics, or register `account_id` as a secondary resolution alias. Neither is correct in all circumstances; the choice depends on the organisation's privacy posture and the analytical requirements. This cannot be automated.

**YouTrack user ID type (OQ-YT-2).** YouTrack user IDs use the format `1-234` — a string, not an integer. Earlier versions of the Silver schema used `UInt64` for `event_author_raw`, which caused a type incompatibility. The correct type is `String` throughout the YouTrack connector. This failure mode is invisible to type inference: the field name `author_id` implies an integer to an automated system, and many user IDs from other connectors are numeric. The type decision requires knowing YouTrack's specific ID format.

**M365 `userPrincipalName` vs `userId`.** M365 Graph API activity tables expose both `userPrincipalName` (the corporate email address, the UPN) and `userId` (Microsoft's internal user GUID). Only `userPrincipalName` is used for identity resolution in Insight — the internal `userId` has no cross-system value. This is a deliberate design decision documented in `m365.md`: the UPN is used, the Microsoft internal ID is not. An automated resolution system that tried both would produce incorrect mappings for users whose Microsoft internal ID happens to match an ID from another system.

---

### 4.7 Data Retention Windows and Collection Frequency Constraints

**M365 Graph API 7–30 day window.** The M365 Graph API reports endpoints return only the last 7 to 30 days of activity data. If the Insight collector fails to run for more than 7 days, the data from that gap is permanently lost and cannot be backfilled. This constraint is documented in `m365.md` as a critical operational requirement: the collector must run at minimum every 7 days. The constraint is not present in the API schema — it is described only in Microsoft's documentation. No automated connector generator can detect it.

The operational consequence is significant: orchestration for the M365 connector must be configured with a tighter schedule than the default, and alerting must be configured to fire if a collection run has not completed within the 7-day window. Neither the schedule nor the alert can be derived from the API contract. They must be explicitly configured by the connector author.

No equivalent constraint exists for YouTrack, Jira, HubSpot, or Salesforce — these systems retain historical data indefinitely. The constraint is M365-specific and cannot be generalised.

---

### 4.8 Privacy and Content Collection Decisions

**Zulip message content.** The Zulip API can return the full text of every message via `GET /api/v1/messages`. Insight deliberately does not collect message text. The `zulip_messages` table contains only aggregated counts per sender per period (`count Float64`, `created_at DateTime64(3)`) — never the content of what was written. This decision is documented in `zulip.md` as a deliberate privacy protection. An automated connector generated from the Zulip API schema would collect message text, violating Insight's data collection policy.

**M365 content fields.** The same decision applies to M365: email body text, meeting transcripts, and Teams message content are accessible via the Graph API but are not collected. Only metadata and counters are stored. The connector author must explicitly exclude these fields — exclusion by default is not how API clients are generated.

**HubSpot contacts as non-persons.** `hubspot_contacts` are external customer records. They have email addresses and names, exactly like internal employee records. The decision not to resolve them to `person_id` is a business logic boundary — these people are not Insight's analytical subjects. Collecting them as reference data without identity resolution is correct; attempting to resolve them as employees would corrupt the Identity Manager with external customer identities. This distinction cannot be derived from the data model.

---

### 4.9 Multi-Instance Disambiguation

The platform supports multiple instances of the same connector type in parallel — five Jenkins instances, two Jira instances, two Zabbix instances, multiple YouTrack deployments across different customer tenants. Every Bronze row carries a `insight_source_id` string that identifies which instance produced it.

The `insight_source_id` value for each instance must be:
- **Human-readable**: `jira-virtuozzo-prod` and `jira-osystems-prod`, not `instance-1` and `instance-2`
- **Stable**: changing a `insight_source_id` after historical data has been collected breaks all historical joins — every existing row that referenced the old value becomes unresolvable
- **Unique across all instances of the same type**: two Jira instances cannot share an ID, even if they are on different customer tenants
- **Meaningful in context**: `youtrack-acme-prod` tells an analyst at a glance which system they are querying; a UUID does not

These properties cannot be auto-generated. They require a human to name each instance deliberately, understanding both the system being connected and the historical data implications of the choice. The `insight_source_id` is effectively a stable foreign key in every Bronze table — it has the same stability requirements as a database primary key.

---

### 4.10 Self-Hosted and Version-Specific API Differences

**Jira REST API v2 vs v3.** Jira Cloud uses REST API v3 (`/rest/api/3/`); Jira Server and Data Center use v2 (`/rest/api/2/`). Endpoint paths differ, field names differ, and changelog format differs. A connector generated from the Jira Cloud OpenAPI schema will not work against a self-hosted Jira Server installation. The connector must detect or be told which version it is communicating with.

**Jenkins.** Jenkins has no standard REST API across versions. Available endpoints depend on installed plugins. Core operations are available via the Jenkins Remote Access API, but the capabilities of a specific Jenkins instance cannot be determined without querying it. A connector for Jenkins must handle capability detection at runtime and is inherently version-dependent.

**1C (ERP).** 1C is a Russian-origin ERP system with no standard REST API. Any integration requires either a custom adapter built against 1C's proprietary API, a third-party middleware connector, or export-based collection from 1C's database. No automated connector generation approach applies.

**SonarQube.** SonarQube is self-hosted, and older versions expose different API endpoint paths than current versions. Endpoint availability must be checked against the installed version at connection time.

---

### 4.11 Silver Mapping Semantics

Automated field mapping can match field names to Silver schema fields by name similarity or type compatibility. It cannot determine analytical equivalence — whether two fields from different systems represent the same fact about the world.

Consider the `outcome` field in `crm_activities`. For HubSpot calls, `outcome` is derived by resolving the `hs_call_disposition` GUID to its label via a separate API call. For HubSpot meetings, it is the direct value of `hs_meeting_outcome`. For Salesforce Tasks, it is the `Status` field. For Salesforce Events, the concept does not exist — Events do not have an outcome status in Salesforce's model.

An automated mapper sees:
- `hs_meeting_outcome: COMPLETED` (HubSpot meetings)
- `Status: Completed` (Salesforce Tasks)

These are two different string values from two different APIs. A human analyst recognises them as the same concept — a completed activity — and maps both to `crm_activities.outcome`. The automated mapper has no basis for this equivalence.

The same applies to the task tracker domain. A YouTrack `State` field change from `In Progress` to `Resolved` and a Jira `status` field change from `In Progress` to `Done` represent the same lifecycle event: a ticket moving from active work to completion. Both should produce the same event type in `class_task_tracker_activities`. The field names differ (`State` vs `status`), the values differ (`Resolved` vs `Done`), and the API structures that carry them differ (YouTrack activity log vs Jira changelog). The semantic equivalence is the entire analytical value of the Silver layer — and it cannot be automated.

---

## 5. The Automation Boundary — A Mental Model

The correct mental model is a line between the structural layer and the semantic layer. Automation works below the line; human authorship is required above it.

The **structural layer** covers everything that is uniform, mechanical, and independent of meaning: authentication protocol, pagination cursor management, HTTP retry logic, collection run logging, metadata column injection, DDL generation from a field declaration. These elements are the same regardless of what the connector collects or why. They can and should be completely automated — any time spent by a connector author on these concerns is waste.

The **semantic layer** covers everything that requires understanding what the data means: which fields to collect, what units they use, how to derive fields that don't exist in the API, what vocabulary each source uses for shared concepts, which users are internal employees and which are not, what not to collect for privacy reasons, how often to collect to avoid data loss. These decisions are irreducibly human. They encode knowledge about the source system, the business domain, and the analytical requirements that no schema inspection can recover.

The line between the two is not the same as the line between framework code and connector code. Some connector code is structural (implementing a pagination cursor that the framework doesn't yet support) and some is semantic (deriving `is_won` from pipeline settings). The goal of the SDK is to absorb all structural code into the framework, leaving connector code to consist exclusively of semantic decisions.

| Layer | Can automate? | Example |
|-------|---------------|---------|
| Auth (OAuth, API key, Basic) | Yes | BambooHR token injection, M365 OAuth flow, Zulip HTTP Basic |
| Pagination | Yes | YouTrack `$skip/$top`, Jira `startAt/maxResults`, HubSpot cursor token |
| Rate limiting and retry | Yes | All connectors — exponential backoff on 429/503 |
| Metadata columns (`collected_at`, `_version`, `data_source`) | Yes | All connectors — injected by base framework |
| `collection_runs` table | Yes | Identical common core across all 17+ connectors |
| `_ext` key-value table structure | Yes | Identical schema in all 8 `_ext` tables |
| Bronze DDL from field list | Yes | Once fields are declared with types |
| Field type inference (simple cases) | Partial | `String`/`Bool`/`Date` yes; duration units no; ID formats no |
| Incremental cursor management | Partial | Where source has standard `updated_since`; not where cursor requires JQL or filter syntax |
| Custom field discovery | No | OQ-YT-3, OQ-JIRA-3 — field name is instance-specific |
| Derived fields (`is_won`, `duration`, `disposition`) | No | OQ-CRM-1 — requires multi-step API logic not in schema |
| Multi-step collection (associations, history) | No | `hubspot_associations`, `youtrack_issue_history` — separate endpoints not visible from main schema |
| Unit normalisation | Partial (AI-assisted) | AI detects probable unit from field name + value range; human confirms — see §7.2 |
| Status/enum normalisation | Partial (AI-assisted) | AI clusters distinct values, proposes mapping; human approves — OQ-CRM-3, see §7.2 |
| Custom field promotion (`_ext` → Silver Map) | Partial (AI-assisted) | AI recommends str/num/drop per key based on cardinality + value patterns; human approves — see §7.2 |
| Identity key candidates | Partial (AI-assisted) | AI flags email-shaped fields and likely external entities; human confirms rules — see §7.2 |
| Identity resolution rules (fallback strategy) | No | OQ-JIRA-1, OQ-HS-1 — what to do when email is suppressed; internal vs external is policy |
| Privacy / content collection decisions | No | Zulip message text, M365 email body, M365 meeting content |
| `insight_source_id` naming | No | Human-assigned, must be stable, must be meaningful |
| Silver semantic mapping (final) | Partial (AI-assisted) | AI drafts field→column mapping via Onboarding UI; human approves — see §7.3 |
| New Silver class creation | Partial (AI-assisted) | AI drafts schema when no match found; human defines and registers class — see §7.4 |
| Data retention constraints | No | M365 7–30 day window — documented in vendor docs, not in API schema |

---

## 6. What This Means for the Connector SDK

The SDK's goal is to absorb the entire structural layer, eliminating boilerplate so that connector authors invest 100% of their effort in the semantic layer — the part that requires expertise and cannot be automated.

The 10-step connector checklist from `CONNECTORS_ARCHITECTURE.md` maps onto this boundary as follows:

**Steps the SDK handles automatically (the author declares, does not code):**

1. `connector.yaml` — generated from a template; author fills in source identity, auth type, endpoint declarations, and pagination type
2. Base class inheritance — the author's connector class extends `BaseConnector`; all protocol mechanics are inherited
3. `{source}_collection_runs` table — generated from the manifest; the author declares per-entity count field names only
4. `{source}_{entity}_ext` table — generated on declaration of `has_custom_fields: true` in the endpoint spec
5. Metadata column injection (`collected_at`, `_version`, `data_source`, `insight_source_id`) — framework-owned, not written by connector authors
6. Bronze DDL generation — generated from the field declaration in the manifest or a companion schema file
7. AirByte/Dagster orchestration registration — generated from the manifest; the author declares the schedule and retry policy

**Steps the author must implement or approve (the semantic contract):**

1. Source adapter implementation (`src/client.py`) — API client, multi-step collection patterns, derived field computation, custom field discovery. Structural scaffolding generated; business logic authored manually.
2. Unifier mapping (`unifier_mapping.yaml`) — which source fields map to which Silver fields. **AI-drafted via Onboarding UI** (§7.3); author reviews and approves each mapping, fixes low-confidence proposals.
3. Enum and unit normalisation — how Bronze vocabulary maps to Silver enumerations; unit conversions for duration, size, currency. **AI proposes** based on distinct value analysis (§7.2); author confirms or overrides.
4. Identity resolution rules (`identity/aliases_{source}.yaml`) — which user type is resolved, which resolution strategy applies. **AI identifies candidates** (email-shaped fields, likely external entities); author confirms the rules and specifies fallback strategy for suppressed emails and dual user models.
5. Custom field promotion list — which `_ext` keys surface in Silver `Map(String,String)` or `Map(String,Float64)`. **AI recommends** based on cardinality and value type analysis (§7.2); author approves and labels promoted fields.
6. Privacy exclusions and data retention constraints — what not to collect, how far back to pull. Always manual; not derivable from Bronze data or API schema.
7. New Silver class definition — when no existing `class_*` table fits the data. **AI drafts the schema** (§7.4); author reviews column names, types, and registers the class.

The boundary is not between "easy steps" and "hard steps." It is between steps that require no knowledge of the source domain (structural) and steps that require understanding of what the data means (semantic). The SDK absorbs the structural steps entirely. The AI-assisted onboarding layer (§7) converts the semantic steps from blank-page authorship into proposal review — reducing the cognitive load while preserving human accountability for every semantic decision.

The right measure of a connector SDK's quality is not "how much code does it generate" but "how clearly does it separate the structural contract from the semantic implementation, and how well it supports human review of the semantic layer." A SDK that generates structural boilerplate while leaving the connector author to make undocumented semantic decisions has failed at its core purpose. A SDK that generates the structural layer completely, drafts the semantic layer via AI proposals, and enforces that every proposal is explicitly approved or overridden — and records those decisions in the connector spec — has succeeded.

---

## 7. AI-Assisted Silver Layer Mapping

The Bronze/Silver boundary is where automation ends and authorship begins. AI cannot replace that authorship — but it can draft the first version, narrow the decision space, and surface what the author actually needs to decide. The goal is not to automate Silver mapping, but to eliminate the blank-page problem.

### 7.1 What the AI analyses

When a connector is first connected and Bronze sync has run, the AI analysis job reads directly from ClickHouse:

- **Distinct field values** — the actual vocabulary in each Bronze column; basis for enum normalisation suggestions
- **Field value statistics** — type distribution, nullability rate, cardinality, numeric range; basis for type assignments and custom field promotion decisions
- **Field names** — semantic similarity to known Silver columns and to fields in other connectors' Bronze tables
- **Schema structure** — which tables exist, how they relate via foreign keys, which fields look like identity keys (contain `email`, `user_id`, `account_id`)

The analysis job does not touch the Silver layer. It reads Bronze, computes proposals, writes them to a proposal store. Nothing is applied automatically.

### 7.2 What the AI proposes

**Field → Silver column mapping**

For each Bronze table, the AI proposes which fields map to which Silver column in an existing `class_*` table. The proposal includes a confidence score and the reasoning:

```
youtrack_issues.estimation  →  class_issues.story_points   (0.91 — numeric field, name matches)
youtrack_issues.state       →  class_issues.status         (0.88 — enum field, >10 distinct values)
youtrack_issues.created     →  class_issues.created_at     (0.97 — DateTime64, name match)
youtrack_issues.reporter_id →  class_issues.author_id      (0.74 — ID field, creator semantics)
```

**Enum normalisation**

For fields mapped to a Silver enum column, the AI clusters the distinct Bronze values and proposes a normalisation table:

```
youtrack_issues.state distinct values → class_issues.status
  "In Progress"   →  in_progress
  "Open"          →  open
  "Resolved"      →  done          ← AI inferred from name; human should confirm
  "Fixed"         →  done          ← same
  "Won't Fix"     →  cancelled
  "Duplicate"     →  cancelled
  [unmapped: "Awaiting Info", "On Hold"]  ← flagged, require human decision
```

Unmapped values are always flagged explicitly — the AI never silently drops data.

**Unit conversion**

When a numeric field's unit differs from the Silver target:

```
hs_call_duration  →  crm_activities.duration_seconds
  detected unit: milliseconds  (values: 3000–600000, field name contains "duration")
  proposed conversion: value / 1000
  confidence: 0.82
```

**Custom field promotion**

For `_ext` key-value tables, the AI analyses all key names and their value patterns across collected data and proposes:

```
bamboohr_employee_ext key analysis:
  "salary_band"        →  custom_str_attrs    (string, low cardinality: 6 distinct values)
  "years_experience"   →  custom_num_attrs    (numeric: 0–35, parseable as Float64)
  "cost_centre"        →  custom_str_attrs    (string, joins to org_units)
  "internal_bio_text"  →  DROP                (high cardinality, likely PII, too long for Map)
  "last_review_date"   →  custom_str_attrs    (date string — consider typed column in future)
```

**Identity key candidates**

```
hubspot_contacts.email      →  identity key candidate  (email format, 100% non-null)
  WARNING: hubspot_contacts is likely an external entity (customers, not employees)
  RECOMMENDATION: do not resolve to person_id — set identity_resolution: none
hubspot_owners.email        →  identity key candidate  (email format, 100% non-null)
  RECOMMENDATION: resolve to person_id via email lookup
```

### 7.3 The Connector Onboarding UI

YAML proposals are not sufficient because they require the connector author to manually diff files and reason about changes in a text editor. The onboarding workflow belongs in a UI where proposals are displayed as actionable decisions.

The Connector Onboarding UI is the control surface for the Silver mapping step. It is accessed after Bronze sync has run and AI analysis has produced its proposals.

**Mapping review screen**

Each proposed field mapping is shown as a row with a status indicator:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ youtrack_issues  →  class_issues                               3/14 pending │
├──────────────────────┬──────────────────────┬──────────┬────────────────┤
│ Bronze field         │ Silver column        │ Status   │ Action         │
├──────────────────────┼──────────────────────┼──────────┼────────────────┤
│ id_readable          │ issue_key            │ ✅ Auto  │                │
│ summary              │ title                │ ✅ Auto  │                │
│ estimation           │ story_points         │ 🤖 Prop  │ Approve / Edit │
│ state                │ status               │ 🤖 Prop  │ Approve / Edit │
│ reporter_id          │ author_id            │ 🤖 Prop  │ Approve / Edit │
│ sprint.name          │ sprint_name          │ ⚠️ Review│ Map / Skip     │
│ custom_field_42      │ (no match)           │ ❓ Unmap │ Map / Drop     │
└──────────────────────┴──────────────────────┴──────────┴────────────────┘
```

Statuses:
- **Auto** — high-confidence exact match; applied without review unless overridden
- **Prop** — AI-proposed match above threshold; requires one-click approval or manual override
- **Review** — low-confidence match or ambiguous case; always requires human decision
- **Unmap** — no Silver column found; human chooses: map manually, add to custom attrs, or drop

**Enum mapping screen**

Opened per field when the Silver column is an enum. Shows distinct Bronze values on the left, proposed Silver values on the right. Unmapped values are highlighted. The operator can drag-and-drop or type to override any mapping. New values that appear after the initial setup trigger a re-review notification.

**Custom field promotion screen**

Shows the `_ext` key analysis: a table of keys, their value sample, cardinality, and the AI's `custom_str_attrs` / `custom_num_attrs` / `DROP` recommendation. The operator approves the list or modifies it. Fields promoted to `custom_num_attrs` get a unit label the operator can optionally set.

**Identity resolution screen**

Shows each candidate identity field with the AI's recommendation. The operator confirms: resolve to `person_id`, mark as external (do not resolve), or mark as system user (exclude). For fields where email may be suppressed (Jira Cloud), the operator selects the fallback strategy: use `account_id` as a secondary key, exclude from person-level analytics, or flag the record.

### 7.4 Creating new Silver classes

Not every connector maps cleanly to an existing `class_*` table. A new source may bring a data type that the platform has not seen before — or may represent a domain (e.g., CI/CD runs, code quality scores) where no Silver schema yet exists.

The Onboarding UI surfaces this explicitly. If the AI cannot map >30% of a Bronze table's fields to any existing Silver class, it flags the table:

```
⚠️  jenkins_builds — no matching Silver class found
    Closest match: class_issues (26% field overlap)
    Recommendation: define new class 'class_cicd_runs'
```

The operator can then initiate a **new class definition** flow:

1. **AI drafts the schema** — proposes a `class_cicd_runs` table structure based on the Bronze fields, applying platform conventions (standard metadata columns, `insight_source_id`, `person_id` if an identity field is found, `data_source` enum)
2. **Operator reviews and edits** — column names, types, which fields are required vs optional, whether a Silver Step 2 (person enrichment) applies
3. **Schema is registered** — the new `class_*` table definition is added to the platform's Silver schema registry; it becomes available as a mapping target for all future connectors in the same domain
4. **The onboarding resumes** — now that the class exists, the current connector's Bronze tables can be mapped to it

This is how the Silver layer grows: not by predicting all future data types up front, but by adding classes incrementally as new connectors are onboarded and humans confirm that a new class is warranted.

**Guardrails for new class creation:**

- New classes must follow naming conventions (`class_<domain_noun>`) and include the standard metadata columns
- The UI warns if a proposed new class overlaps significantly with an existing one (possible misclassification)
- New class additions go through a review step if multiple engineers have access to the onboarding tool
- The platform maintains a schema changelog so new class additions are traceable

### 7.5 What remains manual even with AI assistance

AI narrows the decision space but does not eliminate authorship. Some decisions cannot be made from data alone and will always require human confirmation:

| Decision | Why AI cannot make it |
|----------|----------------------|
| Internal vs external entity | Requires understanding of business context (HubSpot contacts = customers, not employees) |
| Privacy exclusions | Whether to collect message text, email body, or call notes is a policy decision |
| Final enum normalisation | "Awaiting Info" — is this `open` or a separate state? Only the analyst who knows the workflow can decide |
| Fallback identity strategy | When email is suppressed, the fallback choice (exclude vs flag vs secondary key) is a product decision |
| New Silver class approval | Whether a new entity type warrants a new class, or should be absorbed into an existing one, requires platform-level judgment |
| Unit disambiguation | If the AI detects a likely unit but confidence is below threshold, the author must confirm from API documentation |

The onboarding UI makes these decisions visible and structured, but it does not answer them. The output of the UI is a complete semantic contract — every field mapped, every enum resolved, every identity rule declared — which then drives both the Silver transformation job and the connector spec documentation automatically.

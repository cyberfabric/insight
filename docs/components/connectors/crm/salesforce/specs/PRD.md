# PRD — Salesforce Connector

<!-- toc -->

- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background--problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
  - [2.2 System Actors](#22-system-actors)
- [3. Operational Concept & Environment](#3-operational-concept--environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 CRM Entity Extraction](#51-crm-entity-extraction)
  - [5.2 Custom Field Extraction](#52-custom-field-extraction)
  - [5.3 Connector Operations](#53-connector-operations)
  - [5.4 Data Integrity](#54-data-integrity)
  - [5.5 Identity Resolution](#55-identity-resolution)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
  - [UC-001 Configure Salesforce Connection](#uc-001-configure-salesforce-connection)
  - [UC-002 Incremental Sync Run](#uc-002-incremental-sync-run)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Resolved Questions](#13-resolved-questions)
- [14. Non-Applicable Requirements](#14-non-applicable-requirements)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The Salesforce Connector extracts contact records, account (company) data, opportunity (deal pipeline) records, activities (Tasks and Events), custom field values (`__c` fields), and user directory data from the Salesforce REST API via SOQL queries and loads them into the Insight platform's Bronze layer. It provides the raw material for measuring sales performance — deal pipeline velocity, win rates, activity-to-close ratios, and workload per salesperson — alongside the existing HubSpot connector in a unified CRM analytics domain.

### 1.2 Background / Problem Statement

Salesforce is the most widely deployed enterprise CRM platform. Insight already supports HubSpot as a CRM source, but many organizations — especially enterprise customers — use Salesforce as their primary sales system. To deliver unified CRM analytics across the organization, Insight must ingest Salesforce data into the same Bronze-to-Silver pipeline that already serves HubSpot.

The Salesforce REST API provides rich data via SOQL (Salesforce Object Query Language) across standard objects: Contacts, Accounts, Opportunities, Tasks, Events, and Users. The connector must handle the differences between Salesforce and HubSpot data models — most notably that Salesforce stores Tasks and Events as separate objects (unlike HubSpot's unified Engagements), uses 18-character Salesforce IDs instead of numeric IDs, and names companies "Accounts" instead of "Companies". Field names are preserved in source-native form at Bronze; normalization happens at Silver.

Salesforce customers heavily customize their schemas with custom fields (`__c` suffix). These fields — such as `Customer_Segment__c` or `Contract_Value__c` — carry business-critical data that standard field extraction misses. The connector must capture custom fields alongside standard fields without requiring schema changes per customer.

**Target Users**:

- Platform operators who configure Salesforce OAuth credentials, object scope, and monitor extraction runs
- Data analysts who consume Salesforce CRM data in Silver/Gold layers alongside HubSpot for unified sales performance metrics
- Sales managers and revenue operations leaders who use pipeline velocity, activity tracking, and win rate data for team performance analysis

**Key Problems Solved**:

- Lack of Salesforce data in the Insight platform, preventing unified CRM analytics across Salesforce and HubSpot teams
- No visibility into deal pipeline progression (stage transitions, time-in-stage) for Salesforce-using sales teams
- Missing activity data (calls, meetings, tasks) needed for effort-to-close analysis and salesperson workload measurement
- No cross-system identity resolution between Salesforce users and other Insight sources (Jira, GitHub, M365, Slack)
- Custom field data (`__c` fields) essential for customer segmentation and pipeline filtering not available from standard field extraction alone

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- Salesforce CRM data extracted with no missed sync windows over a 90-day period (Baseline: no Salesforce extraction; Target: v1.0)
- Per-user Salesforce activity available for identity resolution within 24 hours of extraction (Baseline: N/A; Target: v1.0)
- Salesforce data unified with HubSpot in the `class_crm_*` Silver tables for cross-source sales analytics (Baseline: HubSpot only; Target: v1.0)

**Capabilities**:

- Extract Salesforce contacts, accounts, opportunities, activities (Tasks and Events), and user directory
- Capture custom field values (`__c` fields) alongside standard fields
- Incremental extraction for all entity streams
- Identity resolution via `email` from Salesforce user directory
- OAuth 2.0 Client Credentials Flow authentication

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Salesforce REST API | Salesforce's REST API (`/services/data/v{version}/`) providing access to standard and custom objects via SOQL queries and object endpoints. |
| SOQL | Salesforce Object Query Language — SQL-like query language used to retrieve records from Salesforce objects. Supports filtering, ordering, and relationship queries. |
| Salesforce ID | 18-character case-insensitive globally unique identifier used for all Salesforce records. The `OwnerId` field on most objects references a User record. |
| Connected App | A Salesforce OAuth 2.0 application configuration that grants API access. Provides `client_id` and `client_secret` for the OAuth flow. |
| Custom Field (`__c`) | A customer-defined field on a Salesforce object, identified by the `__c` suffix (e.g., `Customer_Segment__c`). Schema metadata available via the Describe API. |
| Task | A Salesforce activity object representing a to-do item, call log, or follow-up. Uses `ActivityDate` (date only) and `Status` field. |
| Event | A Salesforce activity object representing a calendar event or meeting. Uses `StartDateTime` (datetime) and `DurationInMinutes` field. |
| Account | A Salesforce object representing a company, organization, or business entity. Equivalent to HubSpot's "Company". |
| Opportunity | A Salesforce object representing a deal or potential sale. Tracks stage, amount, probability, and close date. Equivalent to HubSpot's "Deal". |
| Record Type | A Salesforce metadata configuration that determines available picklist values and page layouts for a given object. Identified by `RecordTypeId`. Common examples: "New Business" vs "Renewal" Opportunities. |
| Field-Level Security (FLS) | A Salesforce permission setting that controls visibility of individual fields per user profile. FLS-hidden fields are silently absent from API responses. |
| Compound Field | A Salesforce field type (Address, Name, Geolocation) that returns a structured JSON object rather than a scalar value. Cannot be used in SOQL WHERE clauses. |
| OpportunityFieldHistory | A Salesforce system object that records changes to tracked fields on Opportunity. Requires Field History Tracking to be enabled in Salesforce Setup. |
| Bulk API 2.0 | Salesforce's batch data API for large-volume operations, returning data in batches up to 150MB. Consumes fewer API calls than REST+SOQL for large datasets. |
| Bronze Table | Raw data table in the destination, preserving source-native field names and types without transformation. |

## 2. Actors

### 2.1 Human Actors

#### Platform Operator

**ID**: `cpt-insightspec-actor-sf-operator`

**Role**: Configures Salesforce instance credentials (OAuth 2.0 Client Credentials), selects object scope, and monitors extraction runs.
**Needs**: Ability to configure the connector with Salesforce credentials, filter by object scope, and verify that data is flowing correctly for all streams.

#### Data Analyst

**ID**: `cpt-insightspec-actor-sf-analyst`

**Role**: Consumes Salesforce contact, account, opportunity, and activity data from Silver/Gold layers to build dashboards for deal pipeline velocity, win rates, activity-to-close ratios, and salesperson workload — alongside HubSpot data in unified CRM views.
**Needs**: Complete, gap-free CRM entity data with identity resolution to canonical person IDs for cross-platform aggregation.

### 2.2 System Actors

#### Salesforce REST API

**ID**: `cpt-insightspec-actor-sf-api`

**Role**: External REST API providing access to Contacts, Accounts, Opportunities, Tasks, Events, Users, and custom field metadata. Enforces API call limits per 24-hour rolling window.

#### Identity Manager

**Ref**: `cpt-insightspec-actor-identity-manager`

**Role**: Resolves `email` from Salesforce Bronze user table to canonical `person_id` in Silver step 2. Enables cross-system joins (Salesforce + HubSpot + Jira + GitHub + M365 + Slack, etc.).

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires a Salesforce account with API access enabled and sufficient permissions to query Contacts, Accounts, Opportunities, Tasks, Events, and Users
- Authentication via OAuth 2.0 Client Credentials Flow (External Client App)
- The connector operates as a batch collector with incremental sync
- The connector **SHOULD** run at least daily to maintain timely opportunity stage and activity data
- Salesforce enforces API call limits per 24-hour rolling window (varies by edition); the connector must handle limit errors gracefully

## 4. Scope

### 4.1 In Scope

- Extraction of Salesforce contacts with core fields and account association
- Extraction of accounts (companies) with hierarchy support (`parent_account_id`)
- Extraction of opportunities (deals) with stage, amount, probability, and close date
- Extraction of activities as separate Task and Event streams (merged at Silver)
- Capture of custom field values (`__c` fields) on all entity streams without per-customer schema changes
- Extraction of Opportunity stage history (`OpportunityFieldHistory` for `StageName` and `Amount` fields)
- Extraction of Salesforce user directory for identity resolution (full refresh; SCD Type 2 history handled at Silver)
- Soft-delete detection with deletion flag on all entity records
- Connector execution monitoring
- Incremental sync for all entity streams
- Identity resolution via `email` from user directory
- OAuth 2.0 Client Credentials Flow authentication
- All timestamps normalized to UTC
- `insight_source_id`, `tenant_id`, and `data_source = 'insight_salesforce'` stamped on every record
- Sandbox vs. production org detection during connection configuration

### 4.2 Out of Scope

- Silver/Gold layer transformations — responsibility of the CRM domain pipeline
- Silver step 2 (identity resolution: `email` → `person_id`) — responsibility of the Identity Manager
- Real-time streaming — this connector operates in batch mode
- Salesforce Service Cloud data (Cases, SLAs, customer satisfaction)
- Salesforce Marketing Cloud or Pardot data
- Einstein Analytics or AI prediction data
- Custom object auto-discovery beyond Opportunity and Contact `__c` fields
- Salesforce webhooks or Streaming API (push-based collection)
- Account hierarchy traversal or recursive parent resolution — flat `parent_account_id` is stored; tree-building is a Silver concern
- FieldHistory tracking beyond `StageName` and `Amount` on Opportunity — additional field histories deferred to a future release
- Salesforce Bulk API 2.0 — deferred to DESIGN as an optimization path for large orgs (see Risks)
- Attachment or file downloads from Salesforce

## 5. Functional Requirements

### 5.1 CRM Entity Extraction

#### Extract Contacts

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-contact-extraction`

The connector **MUST** extract Salesforce Contact records with core fields including: contact ID, email, first name, last name, title, associated account ID, record owner ID, record type ID, lead source, creation timestamp, and last modified timestamp.

**Rationale**: Contacts are the primary external-facing CRM entity. Account association and owner linkage enable per-salesperson contact portfolio analysis and account coverage metrics.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Accounts

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-account-extraction`

The connector **MUST** extract Salesforce Account records with core fields including: account ID, name, website, industry, type (Customer/Partner/Prospect), owner ID, record type ID, parent account ID (for hierarchies), creation timestamp, and last modified timestamp.

**Rationale**: Accounts represent companies in the sales pipeline. Account hierarchy data enables roll-up analytics (subsidiary → parent company). Industry and type fields enable segmentation analysis.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Opportunities

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-opportunity-extraction`

The connector **MUST** extract Salesforce Opportunity records with core fields including: opportunity ID, name, stage name, amount, currency ISO code (for multi-currency orgs), close date, probability, owner ID, account ID, record type ID, lead source, is_closed flag, is_won flag, creation timestamp, and last modified timestamp.

**Rationale**: Opportunities are the core entity for deal pipeline analytics — stage progression, time-in-stage, win/loss rates, and pipeline value forecasting all depend on complete opportunity data. `currency_iso_code` is required for multi-currency orgs where amounts are stored in different currencies per record — without it, pipeline value aggregation produces incorrect totals. `record_type_id` enables segmentation by opportunity type (e.g., "New Business" vs. "Renewal").

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Tasks

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-task-extraction`

The connector **MUST** extract Salesforce Task records into a dedicated Bronze stream. Core fields include: task ID, subject, owner ID, who ID (contact/lead reference), who type, what ID (related object reference), what type, activity date, status, call type (call-logged tasks only), call duration seconds (call-logged tasks only), creation timestamp, and last modified timestamp.

**Rationale**: Tasks represent to-do items, call logs, and follow-ups — a core salesperson activity signal. Tasks and Events are kept as separate streams to preserve the source-native 1:1 mapping and are merged at Silver.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Events

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-event-extraction`

The connector **MUST** extract Salesforce Event records into a dedicated Bronze stream. Core fields include: event ID, subject, owner ID, who ID (contact/lead reference), who type, what ID (related object reference), what type, start datetime, end datetime, duration in minutes, creation timestamp, and last modified timestamp.

**Rationale**: Events represent calendar meetings and scheduled activities. Kept as a separate stream from Tasks to preserve source-native schema; merged at Silver.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Resolve Polymorphic References on Activities

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-polymorphic-resolution`

Task and Event streams extract raw `WhoId` and `WhatId` polymorphic references at Bronze. Polymorphic resolution to specific object types (Contact, Lead, Account, Opportunity) is performed at Silver using Salesforce ID key prefixes (e.g., `003` = Contact, `006` = Opportunity, `001` = Account). The Silver transformation **MUST** derive `contact_id`, `deal_id`, and `account_id` from `WhoId`/`WhatId` based on these prefixes.

**Rationale**: Salesforce ID key prefixes are stable and well-documented. Resolving at Silver (dbt) avoids adding custom Python logic to the declarative connector while still providing unambiguous entity references for downstream analytics.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Opportunity Stage History

- [ ] `p2` - **ID**: `cpt-insightspec-fr-sf-opportunity-history`

The connector **MUST** extract the `OpportunityFieldHistory` object for the `StageName` and `Amount` fields, including: opportunity ID, field name, old value, new value, change timestamp (`CreatedDate`), and the user who made the change (`CreatedById`).

**Rationale**: The PRD's stated goals include "deal pipeline velocity" and "time-in-stage" analytics. The current `salesforce_opportunities` table captures only the current snapshot — it cannot answer "how long was this deal in Negotiation?" or "when did it move from Qualification to Proposal?". `OpportunityFieldHistory` is the Salesforce equivalent of Jira's changelog, which the Jira connector treats as P1. Without stage history, only current-snapshot pipeline analytics are possible, not the time-series pipeline velocity metrics that distinguish Insight from basic CRM reporting. Stage history for `StageName` and `Amount` is a minimal viable set; additional fields (e.g., `CloseDate`, `Probability`) can be added in a future release.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract User Directory

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-user-extraction`

The connector **MUST** extract the Salesforce user directory, including: user ID (18-char Salesforce ID), email, first name, last name, title, department, profile name (requires `Profile.Name` relationship query), and active status.

**Rationale**: The user directory provides the email identity key for cross-system resolution and the salesperson roster needed to associate all owned CRM objects with their operators.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-identity-manager`

#### Preserve User Directory History (SCD Type 2)

- [ ] `p2` - **ID**: `cpt-insightspec-fr-sf-user-scd`

The `users` stream extracts the current-state user directory via full refresh. SCD Type 2 history tracking (detecting changes in email, title, department, active status between syncs and maintaining `valid_from`/`valid_to` temporal bounds) is a **Silver-layer responsibility**, not a connector concern. The connector emits the current snapshot on each run; the Silver dbt model compares against the previous snapshot to detect changes and maintain the historical record.

**Rationale**: The Salesforce User API returns current state only. SCD Type 2 is needed for historical analytics and identity resolution disambiguation (e.g., email reuse on deactivated accounts). However, change detection logic belongs at the transformation layer (Silver/dbt), not in the extraction connector. The connector's role is to deliver the full current snapshot reliably; the Silver layer owns the semantic interpretation of what changed. This keeps the connector simple (declarative YAML, full refresh) and avoids duplicating change-detection logic that dbt handles natively via snapshot models.

**Actors**: `cpt-insightspec-actor-sf-analyst`, `cpt-insightspec-actor-identity-manager`

#### Validate Field-Level Security Coverage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-fls-validation`

During connection configuration (UC-001), the connector **MUST** call the Describe API for each target object and compare the fields returned against the Bronze schema's expected field set. If any schema-defined field is not visible to the authenticated user (due to Salesforce Field-Level Security restrictions), the connector **MUST** log a warning listing all hidden fields and their parent object. The connector **MUST NOT** fail extraction due to FLS-hidden fields — it **MUST** emit `null` for hidden fields and continue.

At the start of each sync run, the connector **SHOULD** re-validate FLS coverage and include a summary of hidden fields in the collection run log.

**Rationale**: Salesforce Field-Level Security (FLS) can make specific fields invisible to the API user without returning an error. A SOQL query succeeds but the restricted field is simply absent from the response. Without proactive FLS validation, the connector silently produces incomplete records (e.g., `Amount` missing from Opportunities, `Email` missing from Contacts) with no indication to the operator. This is particularly dangerous for identity resolution — if `email` is FLS-restricted on the User object, the entire identity chain breaks silently.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-operator`

### 5.2 Custom Field Extraction

#### Capture Custom Fields via `raw_data` JSON Column

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-custom-fields`

All entity streams **MUST** capture custom fields (`__c` suffix) alongside standard fields without requiring per-customer schema changes. The full API response payload — including both standard and custom fields — **MUST** be preserved for each record so that Silver-layer transformations can extract and promote selected custom fields.

**Rationale**: Organization-specific custom fields (customer segment, product line, region) are essential for pipeline filtering and segmentation analytics. Capturing them generically avoids schema changes when customers add new `__c` fields and preserves source-native types.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

### 5.3 Connector Operations

#### Track Collection Runs

- [ ] `p2` - **ID**: `cpt-insightspec-fr-sf-collection-runs`

Collection run metadata (run ID, start/end time, status, per-stream record counts, error counts) **SHOULD** be available for operational monitoring. API budget consumption **SHOULD** be trackable to enable operators to monitor usage trends against Salesforce edition limits.

**Actors**: `cpt-insightspec-actor-sf-operator`

### 5.4 Data Integrity

#### Deduplicate by Primary Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-deduplication`

Each stream **MUST** define a primary key that ensures re-running the connector for an overlapping date range does not produce duplicate records.

The connector **MUST** generate a surrogate URN-based primary key for entity records in the format `urn:salesforce:{tenant_id}:{source_instance_id}:{record_id}`. The original `source_instance_id`, `tenant_id`, and Salesforce 18-char ID fields **MUST** be preserved as separate columns for filtering and joins. The URN key eliminates the need for composite key joins in downstream analytics.

Custom field ext streams use `(source_instance_id, entity_id, field_api_name)` as the composite key.

The Airbyte sync mode for all entity streams (contacts, accounts, opportunities, activities, opportunity history) **MUST** be **Incremental | Append + Deduped** (upsert/merge semantics). The `salesforce_users` stream **MUST** use **Full Refresh | Append** with SCD Type 2 handling (see `cpt-insightspec-fr-sf-user-scd`). The `salesforce_deleted_records` stream **MUST** use **Incremental | Append**.

**Rationale**: Without explicit upsert semantics, overlapping incremental windows produce duplicate rows. URN-based surrogate keys provide unambiguous cross-org identity while keeping component fields available for filtering, matching the pattern established by the Jira connector (`urn:jira:{tenant_id}:{source_instance_id}:{issue_key}`).

**Actors**: `cpt-insightspec-actor-sf-api`

#### Support Incremental Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-incremental-sync`

The connector **MUST** support incremental collection for all entity streams, so that ongoing runs process only newly created or modified records without requiring full reloads.

**Known limitation**: Incremental sync is blind to hard-deleted records (permanently purged from Recycle Bin). Soft-deleted records are captured via the deletion detection mechanism (see `cpt-insightspec-fr-sf-deleted-records`). Permanently purged records are invisible to all API endpoints. The connector **SHOULD** support periodic full reconciliation to detect permanently purged records.

**Rationale**: Full reloads are impractical for large Salesforce instances with millions of records across objects. Incremental sync is required for sustainable daily operation.

**Actors**: `cpt-insightspec-actor-sf-operator`

#### Detect Deleted Records

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-deleted-records`

All entity streams **MUST** capture soft-deleted records (those in the Salesforce Recycle Bin) alongside active records, with a deletion flag (`IsDeleted`) on every record. Deleted records must be included in the normal extraction flow — no separate deleted-records stream is required.

**Rationale**: For CRM analytics, stale opportunities inflating the pipeline is a data quality problem. If a salesperson deletes a lost Opportunity, the Bronze layer must reflect that deletion within the same day's sync. Salesforce retains soft-deleted records in the Recycle Bin for 15 days (default) before permanent purge. Permanently purged records are invisible to all API endpoints and require periodic full reconciliation to detect.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Handle API Call Limits

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-api-limits`

The connector **MUST** handle Salesforce API limit errors gracefully with retry and backoff. If the limit persists, the sync should fail cleanly with cursor state preserved for resumption on the next run.

The connector **SHOULD** be scheduled during off-peak hours to minimize contention with other org integrations.

**Rationale**: Salesforce API call limits are shared across all integrations in the org. Exhausting the daily budget blocks other business-critical integrations (e.g., marketing automation, customer support tools). The connector must be a responsible consumer of the shared API budget.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-operator`

#### Preserve Source-Native Field Names

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-field-preservation`

All Salesforce API fields **MUST** be preserved in their source-native PascalCase form at Bronze level (e.g., `OwnerId`, `AccountId`, `LastModifiedDate`). Field name normalization to snake_case is a Silver-layer responsibility, handled by dbt transformations alongside cross-source schema unification.

**Rationale**: The platform's architecture principle is that Bronze preserves source-native schema. Normalizing at Bronze would mean the Bronze layer no longer matches the API response, complicating debugging and violating the "raw archive" contract.

**Actors**: `cpt-insightspec-actor-sf-api`

### 5.5 Identity Resolution

#### Expose Identity Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-identity-key`

All user-attributed streams **MUST** include `owner_id` (18-char Salesforce User ID) that joins to `salesforce_users.user_id`. The user directory **MUST** include `email` as the identity resolution key.

The Identity Manager (Silver step 2) resolves identity as follows:
1. `salesforce_users.email` → canonical `person_id` via the standard email resolution path
2. `salesforce_contacts.email` is for external customers — not resolved to `person_id` (same boundary as HubSpot contacts)

**Rationale**: Cross-system identity resolution is the foundation of the Insight platform's analytics. Email is the canonical cross-system key. The internal/external boundary (users = salespeople = resolved; contacts = customers = not resolved) matches the HubSpot connector's identity model.

**Actors**: `cpt-insightspec-actor-identity-manager`

#### Stamp Instance and Tenant Context

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-instance-context`

Every record emitted by the connector **MUST** include `insight_source_id` (identifying the specific Salesforce org), `tenant_id` (identifying the Insight tenant), and `data_source` (set to `insight_salesforce` for all records). These fields are required for multi-instance disambiguation, tenant isolation, and source identification when Salesforce data merges with HubSpot data in unified `class_crm_*` Silver tables.

**Rationale**: Multiple Salesforce orgs (production, sandbox, acquired companies) may feed into the same Bronze store. Without `insight_source_id`, Salesforce 18-char IDs could collide across orgs. The `data_source` field enables the Silver pipeline to distinguish Salesforce-originated records from HubSpot-originated records in the unified CRM schema, matching the pattern established by the Slack connector (`data_source = 'insight_slack'`).

**Actors**: `cpt-insightspec-actor-sf-operator`

#### Normalize Timestamps to UTC

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-utc-timestamps`

All timestamps persisted in the Bronze layer **MUST** be stored in UTC. Salesforce API returns timestamps in ISO 8601 format with timezone offsets (typically UTC already, but the connector **MUST** normalize any non-UTC offsets). Activity dates **MUST** preserve the date-only (`Date`) vs datetime (`DateTime64(3)`) distinction from the source (Tasks use `ActivityDate` as date; Events use `StartDateTime` as datetime).

**Rationale**: Consistent UTC normalization prevents timezone-related errors in cross-platform analytics, especially for globally distributed sales teams.

**Actors**: `cpt-insightspec-actor-sf-analyst`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Data Freshness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-sf-freshness`

The connector **MUST** deliver extracted data to the Bronze layer within 24 hours of the connector's scheduled run.

**Threshold**: Data available in Bronze ≤ 24h after scheduled collection time.

**Rationale**: Timely opportunity and activity data enables near-real-time pipeline dashboards. Stale data reduces the value of sales performance analysis and forecasting.

#### Extraction Completeness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-sf-completeness`

The connector **MUST** extract all records matching the configured object scope and date range on each successful run. Failed or partial runs must be detectable and retryable without data loss.

**Rationale**: Incomplete extraction leads to understated pipeline values, incorrect win rates, and unreliable activity-to-close metrics.

#### Timestamp Normalization

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-sf-utc-timestamps`

All timestamps persisted in the Bronze layer **MUST** be stored in UTC (ISO 8601 format).

**Threshold**: Zero non-UTC timestamps in Bronze tables.

**Rationale**: Salesforce returns timestamps with timezone information. For globally distributed sales teams, inconsistent timestamp storage would corrupt time-based analytics at the Silver/Gold layer.

### 6.2 NFR Exclusions

- **Real-time streaming latency**: Not applicable — this connector operates in batch mode with daily incremental sync.
- **Throughput / high-volume optimization**: Not applicable for most streams. Large Salesforce orgs may require SOQL pagination tuning but the API handles this natively via `queryMore`.
- **Availability**: Batch connector — availability is determined by the orchestrator's scheduling, not by this connector.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Salesforce Stream Contract

- [ ] `p1` - **ID**: `cpt-insightspec-interface-sf-streams`

**Type**: Data format (Bronze table schemas)

**Stability**: stable

**Description**: Seven Bronze streams:

| Stream | Salesforce Object | Sync Mode | Description |
|--------|------------------|-----------|-------------|
| `accounts` | Account | Incremental | Companies and organizations |
| `contacts` | Contact | Incremental | External people at accounts |
| `opportunities` | Opportunity | Incremental | Deals in the pipeline |
| `opportunity_history` | OpportunityFieldHistory | Incremental | Stage and amount change history |
| `tasks` | Task | Incremental | To-dos, call logs, follow-ups |
| `events` | Event | Incremental | Calendar meetings, scheduled activities |
| `users` | User | Full refresh | Internal salesperson directory |

Tasks and Events are separate streams, merged at Silver. All entity streams include soft-deleted records with `IsDeleted` flag. Field names are preserved in source-native PascalCase. All records include `data_source`, `tenant_id`, `source_instance_id`, and URN-based `pk`.

**Field-level schemas**: Defined in [`salesforce.md`](../salesforce.md) (Bronze table definitions with column types, descriptions, and API field mappings).

**Breaking Change Policy**: Adding new fields is non-breaking. Removing or renaming fields requires a migration.

### 7.2 External Integration Contracts

#### Salesforce REST API

- [ ] `p1` - **ID**: `cpt-insightspec-contract-sf-rest-api`

**Direction**: required from external system

**Protocol/Format**: REST / JSON (SOQL queries)

| Stream | Salesforce Object | Sync |
|--------|------------------|------|
| `contacts` | Contact | Incremental |
| `accounts` | Account | Incremental |
| `opportunities` | Opportunity | Incremental |
| `tasks` | Task | Incremental |
| `events` | Event | Incremental |
| `opportunity_history` | OpportunityFieldHistory | Incremental |
| `users` | User | Full refresh |

**Authentication**: OAuth 2.0 Client Credentials Flow (External Client App)

**Compatibility**: Salesforce REST API v66.0. Response format is JSON with cursor-based pagination. Field additions are non-breaking.

## 8. Use Cases

### UC-001 Configure Salesforce Connection

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-sf-configure`

**Actor**: `cpt-insightspec-actor-sf-operator`

**Preconditions**:

- Salesforce org with API access enabled
- External Client App created in Salesforce with Client Credentials Flow enabled

**Main Flow**:

1. Operator provides `instance_url`, `client_id`, `client_secret`, `tenant_id`, and `source_instance_id`
2. System validates credentials against the Salesforce API
3. System discovers the org type (production vs. sandbox) from the instance URL
4. If sandbox detected: system displays a warning that sandbox data may duplicate production records and labels the connection as `sandbox` in `source_instance_id` metadata
7. System queries the Describe API for each target object and validates Field-Level Security (FLS) coverage — reports any schema-defined fields that are not visible to the authenticated user
8. System presents available objects and custom field metadata
9. Operator confirms object scope (default: all standard objects + all `__c` fields on Opportunity and Contact)
10. System pins the API version (default: latest stable, operator can override) and initializes the connection with empty state

**Postconditions**:

- Connection is ready for first sync run
- Authentication credentials are securely stored
- Org type (production/sandbox) recorded in connection metadata
- FLS coverage report available for operator review

**Alternative Flows**:

- **Invalid credentials**: System reports authentication failure; operator corrects credentials
- **Insufficient API permissions**: System reports which objects are inaccessible; operator adjusts user profile permissions
- **FLS-hidden fields**: System reports which schema-defined fields are not visible due to FLS; operator adjusts field-level permissions or acknowledges gaps
- **API not enabled**: System detects API access is disabled for the org/user; operator enables API access in Salesforce Setup
- **App not authorized**: OAuth returns `invalid_app_access`; operator assigns profile/permission set to the External Client App
- **Sandbox org detected**: System warns about sandbox data duplication risk; operator confirms or cancels

### UC-002 Incremental Sync Run

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-sf-incremental-sync`

**Actor**: `cpt-insightspec-actor-sf-operator`

**Preconditions**:

- Connection configured and credentials valid
- Previous state available (or empty for first run)

**Main Flow**:

1. Orchestrator triggers the connector with current state
2. Connector queries each entity stream incrementally (only records modified since last cursor)
3. All fields — standard and custom (`__c`) — are captured for each record
4. Tasks and Events are extracted as separate streams with independent cursors
5. User directory is refreshed via full refresh
6. Updated cursor position captured after successful write

**Postconditions**:

- Bronze tables contain new and updated records
- State updated with latest cursor per stream
- Sync logs record success/failure and per-stream counts

**Alternative Flows**:

- **First run**: Connector extracts all records matching the object scope (full initial load)
- **API limit exhausted**: Connector retries with backoff; if limit persists, sync fails. Cursor state is preserved for resumption
- **Pagination**: Large result sets are paginated automatically; no truncated results
- **Permission gaps**: If the user lacks permission for certain fields, connector emits `null` and logs a warning

## 9. Acceptance Criteria

- [ ] Contacts, accounts, and opportunities extracted from a live Salesforce org with core fields including `record_type_id` and `currency_iso_code` (opportunities)
- [ ] Opportunity stage history (`StageName`, `Amount`) extracted from `OpportunityFieldHistory`
- [ ] Tasks and Events extracted as separate Bronze streams (`salesforce_tasks`, `salesforce_events`) with independent cursors; `who_type` and `what_type` polymorphic discriminators populated on both
- [ ] User directory extracted with email, title, department, profile, and active status; SCD Type 2 preserves historical state
- [ ] Custom fields (`__c`) captured alongside standard fields on all entity streams
- [ ] Incremental sync on second run extracts only newly modified records (no full reload)
- [ ] `owner_id` joins to `salesforce_users.user_id` in all user-attributed records
- [ ] URN-based surrogate primary keys (`urn:salesforce:{tenant_id}:{source_instance_id}:{record_id}`) on all entity streams
- [ ] `source_instance_id`, `tenant_id`, and `data_source = 'insight_salesforce'` present in all records
- [ ] All timestamps stored in UTC
- [ ] Source-native field names preserved in all Bronze tables
- [ ] Soft-deleted records captured with deletion flag, no separate stream
- [ ] API call limit errors handled gracefully with retry/backoff

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Salesforce REST API | Data extraction for all CRM entities and field metadata | `p1` |
| Salesforce credentials | OAuth 2.0 Client Credentials Flow via External Client App | `p1` |
| Airbyte Connector framework | Connector execution and orchestration | `p1` |
| Identity Manager | Resolves `email` to `person_id` in Silver step 2 | `p2` |
| ClickHouse | Bronze layer destination store | `p1` |

## 11. Assumptions

- The Salesforce org has API access enabled and the authenticated user has read permissions across Contacts, Accounts, Opportunities, Tasks, Events, and Users
- Authentication uses OAuth 2.0 Client Credentials Flow via External Client App
- Tasks and Events are separate Salesforce objects, extracted as separate Bronze streams and merged at Silver
- Bronze tables preserve source-native field names; normalization is a Silver-layer responsibility
- Custom fields (`__c` suffix) are discoverable via the Describe API and captured alongside standard fields
- Salesforce API call limits are shared across all integrations in the org
- Soft-deleted records are in the Recycle Bin for 15 days by default; permanently purged records are invisible to all API endpoints
- Contact emails represent external customers and are not resolved to `person_id`; only user emails (internal salespeople) participate in identity resolution
- Account hierarchy (`ParentId`) is stored as a flat reference; tree-building is a Silver/Gold concern
- `WhoId` and `WhatId` on Task and Event objects are polymorphic references that must be resolved to their object types
- `OpportunityFieldHistory` requires Field History Tracking to be enabled in Salesforce Setup; if not enabled, the stream is empty
- `RecordTypeId` and `CurrencyIsoCode` are available on some orgs but not all (Record Types and Multi-Currency must be enabled)
- Sandbox orgs have different login URLs, lower API limits, and may contain stale copies of production data
- Field-Level Security (FLS) can silently hide fields from the API response without returning an error

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| API call limit exhaustion | Salesforce API limits are shared across all org integrations; exceeding the daily limit blocks other business-critical tools | Schedule runs during off-peak hours; retry with backoff on limit errors; preserve cursor state for resumption |
| Custom field schema drift | Customers add, rename, or remove `__c` fields between runs | Custom fields are captured generically — new fields appear automatically, removed fields stop appearing. No schema migration needed |
| Large Salesforce orgs | Initial full load may consume significant API calls and take extended time | Paginate results; support resumable state for interrupted initial loads |
| Tasks vs Events merge at Silver | Two separate Bronze streams must be unified at Silver with shared semantics | Standard cross-source normalization pattern, same as HubSpot engagement types |
| OAuth token expiration | Client credentials tokens expire; admin can revoke Connected App access | Re-authenticate on token expiry; alert operator on authentication failures |
| Multi-org ID collisions | Multiple Salesforce orgs may have overlapping 18-char IDs | URN-based primary keys and `source_instance_id` ensure unique identification |
| Soft-deleted records inflating pipeline | Without deletion detection, deleted Opportunities remain "active" in analytics | Soft-deleted records captured with `IsDeleted` flag — see FR `cpt-insightspec-fr-sf-deleted-records`. Permanently purged records require periodic full reconciliation |
| Custom field capture | Custom `__c` fields must be accessible without per-deployment schema changes | Full API response captured per record — see FR `cpt-insightspec-fr-sf-custom-fields` |
| Inactive user ownership | Deactivated users still own historical records | Extract all users regardless of active status; filter at analytics layer |
| Field-Level Security (FLS) | FLS-restricted fields are silently absent from API responses | Validate FLS coverage at configuration; log hidden fields; emit `null` for missing fields — see FR `cpt-insightspec-fr-sf-fls-validation` |
| Sandbox data pollution | Sandbox orgs connected alongside production produce duplicate or stale records | Detect sandbox vs. production at connection time; label connections; warn operators |
| Email reuse on deactivated accounts | Email reassigned to new hire creates identity resolution collisions | SCD Type 2 at Silver maintains temporal bounds for disambiguation — see FR `cpt-insightspec-fr-sf-user-scd` |
| Polymorphic references | Activity `WhoId`/`WhatId` reference multiple object types; without type discriminators, joins are ambiguous | Resolved at Silver via Salesforce ID key prefixes (`003`=Contact, `006`=Opportunity, `001`=Account) — see FR `cpt-insightspec-fr-sf-polymorphic-resolution` |
| Multi-currency amounts | Orgs with Multi-Currency store amounts in different currencies per Opportunity | `CurrencyIsoCode` collected where available; Silver normalizes to common currency |
| API version deprecation | Salesforce retires API versions ~3 years after release | Monitor release calendar; update connector before version reaches end-of-life |
| OpportunityFieldHistory not enabled | Field History Tracking must be explicitly enabled in Salesforce Setup | Warn operator if history tracking is disabled; empty stream is expected |

## 13. Resolved Questions

All open questions from the connector specification (`salesforce.md`) have been resolved and incorporated into the PRD as concrete requirements:

| ID | Summary | Resolution | Incorporated In |
|----|---------|------------|-----------------|
| OQ-SF-1 | Tasks vs Events — unified or separate Bronze tables | Separate Bronze streams. Each stream has its own schema and cursor. Merged at Silver. Follows the source-native 1:1 mapping principle (one Salesforce object = one Bronze table). | FR `cpt-insightspec-fr-sf-task-extraction`, FR `cpt-insightspec-fr-sf-event-extraction` |
| OQ-SF-2 | Custom `__c` fields — collection scope | All custom fields captured automatically alongside standard fields on every entity stream. No separate `_ext` tables needed. Silver extracts and promotes selected custom fields. | FR `cpt-insightspec-fr-sf-custom-fields` |

## 14. Non-Applicable Requirements

The following checklist domains have been evaluated and determined not applicable for this connector:

| Domain | Reason |
|--------|--------|
| **Security (SEC)** | The connector handles OAuth tokens or username/password credentials, stored as `airbyte_secret` by the Airbyte framework. No custom authentication, authorization, or encryption logic exists in the connector. Credential storage and secret management are delegated to the Airbyte platform. |
| **Safety (SAFE)** | Pure data extraction pipeline. No interaction with physical systems, no potential for harm to people, property, or environment. |
| **Performance (PERF)** | Batch connector with native SOQL pagination (`queryMore`). No caching, pooling, or latency optimization needed. API call limit handling is the only performance concern, covered in FR `cpt-insightspec-fr-sf-api-limits`. |
| **Reliability (REL)** | Idempotent extraction via deduplication keys (Salesforce 18-char IDs). No distributed state, no transactions. Recovery is handled by re-running the sync (Airbyte framework manages state). |
| **Usability (UX)** | No user-facing interface. Configuration is a credential form and object scope selection in the Airbyte UI. No accessibility, internationalization, or inclusivity requirements apply. |
| **Compliance (COMPL)** | Salesforce user emails and contact emails are personal data under GDPR. Retention, deletion, and data subject rights are delegated to the Airbyte platform and destination operator. The connector must not store credentials outside the platform's secret management. |
| **Maintainability (MAINT)** | Declarative connector manifest. Schema changes are handled by updating field definitions in the manifest. Custom field capture is generic and requires no per-customer changes. |
| **Testing (TEST)** | Connector behavior must satisfy PRD acceptance criteria (Section 9). Validation includes: Airbyte framework connection check, schema validation, and connector-specific acceptance tests. No custom unit tests required — the declarative manifest is validated by the framework. |

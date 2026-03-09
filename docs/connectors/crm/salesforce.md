# Salesforce Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 17 (Salesforce)

Standalone specification for the Salesforce (CRM) connector. Expands Source 17 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`salesforce_contacts`](#salesforcecontacts)
  - [`salesforce_accounts` — Company / account records](#salesforceaccounts-company-account-records)
  - [`salesforce_opportunities` — Deal pipeline records](#salesforceopportunities-deal-pipeline-records)
  - [`salesforce_activities` — Tasks and Events](#salesforceactivities-tasks-and-events)
  - [`salesforce_users` — User directory](#salesforceusers-user-directory)
  - [`salesforce_collection_runs` — Connector execution log](#salesforcecollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-SF-1: Tasks vs Events — unified or separate Silver tables](#oq-sf-1-tasks-vs-events-unified-or-separate-silver-tables)
  - [OQ-SF-2: Custom `__c` fields — collection scope](#oq-sf-2-custom-c-fields-collection-scope)

<!-- /toc -->

---

## Overview

**API**: Salesforce REST API + SOQL query language

**Category**: CRM

**Authentication**: OAuth 2.0 (Connected App) or username/password + security token

**Identity**: `salesforce_users.email` — internal salespeople resolved to canonical `person_id` via Identity Manager.

**Field naming**: snake_case — Salesforce API uses PascalCase (e.g. `OwnerId`, `AccountId`) but normalised to snake_case at Bronze level.

**Why multiple tables**: Same modular CRM object model as HubSpot — contacts, accounts, opportunities, activities, and users are separate Salesforce objects joined by 18-char IDs.

**Key differences from HubSpot:**

| Aspect | HubSpot | Salesforce |
|--------|---------|-----------|
| Companies | Companies | Accounts |
| Deals | Deals | Opportunities |
| Activities | Engagements (unified) | Tasks + Events (separate objects) |
| User ID | `owner_id` (numeric) | `OwnerId` (18-char Salesforce ID) |
| Custom fields | Portal properties | Custom `__c` fields (schema-driven) |
| History | Separate history objects | `FieldHistory` tracking per object |

**Primary use in Insight**: linking commercial activity to salespeople (`salesforce_users`) for workload and performance analytics. Opportunities enable deal pipeline analytics.

---

## Bronze Tables

### `salesforce_contacts`

| Field | Type | Description |
|-------|------|-------------|
| `contact_id` | text | Salesforce 18-char ID |
| `email` | text | Primary email — CRM contact email (external customer) |
| `first_name` | text | First name |
| `last_name` | text | Last name |
| `title` | text | Job title |
| `account_id` | text | Associated Account (company) ID — joins to `salesforce_accounts.account_id` |
| `owner_id` | text | Record owner (salesperson) Salesforce ID — joins to `salesforce_users.user_id` |
| `lead_source` | text | Lead origin |
| `created_date` | timestamptz | Record creation |
| `last_modified_date` | timestamptz | Last update — cursor for incremental sync |

---

### `salesforce_accounts` — Company / account records

| Field | Type | Description |
|-------|------|-------------|
| `account_id` | text | Salesforce 18-char ID |
| `name` | text | Account name |
| `website` | text | Website URL |
| `industry` | text | Industry |
| `type` | text | `Customer` / `Partner` / `Prospect` / etc. |
| `owner_id` | text | Account owner ID — joins to `salesforce_users.user_id` |
| `parent_account_id` | text | Parent account for hierarchies (NULL for root) |
| `created_date` | timestamptz | Record creation |
| `last_modified_date` | timestamptz | Last update |

---

### `salesforce_opportunities` — Deal pipeline records

| Field | Type | Description |
|-------|------|-------------|
| `opportunity_id` | text | Salesforce 18-char ID |
| `name` | text | Opportunity name |
| `stage_name` | text | Current stage, e.g. `Prospecting` / `Closed Won` / `Closed Lost` |
| `amount` | numeric | Opportunity amount |
| `close_date` | date | Expected or actual close date |
| `probability` | numeric | Win probability (0–100) |
| `owner_id` | text | Opportunity owner ID — joins to `salesforce_users.user_id` |
| `account_id` | text | Associated account |
| `lead_source` | text | Lead origin |
| `is_closed` | boolean | Whether the opportunity is closed |
| `is_won` | boolean | Whether the outcome was a win |
| `created_date` | timestamptz | Record creation |
| `last_modified_date` | timestamptz | Last update |

---

### `salesforce_activities` — Tasks and Events

Salesforce stores Tasks and Events as separate objects. This table merges both with a discriminator field.

| Field | Type | Description |
|-------|------|-------------|
| `activity_id` | text | Salesforce 18-char ID |
| `activity_type` | text | `Task` / `Event` |
| `subject` | text | Activity subject / title |
| `owner_id` | text | Activity owner — joins to `salesforce_users.user_id` |
| `who_id` | text | Contact or Lead associated (nullable) |
| `what_id` | text | Related object — Opportunity, Account, etc. (nullable) |
| `activity_date` | date | Due date for Tasks (`ActivityDate`); NULL for Events |
| `activity_datetime` | timestamptz | Start datetime for Events (`StartDateTime`); NULL for Tasks |
| `duration_minutes` | numeric | Duration in minutes (`DurationInMinutes`) — Events only; NULL for Tasks |
| `status` | text | Task status: `Not Started` / `In Progress` / `Completed` / etc. (`Status`) — NULL for Events |
| `call_type` | text | `Inbound` / `Outbound` / `Internal` (`CallType`) — call-logged Tasks only; NULL otherwise |
| `call_duration_seconds` | numeric | Call duration in seconds (`CallDurationInSeconds`) — call-logged Tasks only; NULL otherwise |
| `created_date` | timestamptz | Record creation |

**Note**: Tasks and Events have different date fields — Tasks use `ActivityDate` (date only), Events use `StartDateTime` (datetime). Both are collected via SOQL: `SELECT ... FROM Task` and `SELECT ... FROM Event` separately, merged here with `activity_type` discriminator.

---

### `salesforce_users` — User directory

| Field | Type | Description |
|-------|------|-------------|
| `user_id` | text | Salesforce 18-char user ID — joins to `owner_id` in other tables |
| `email` | text | Email — identity resolution key for internal salespeople |
| `first_name` | text | First name |
| `last_name` | text | Last name |
| `title` | text | Job title |
| `department` | text | Department |
| `profile` | text | Salesforce profile name (`Profile.Name`) — requires JOIN in SOQL: `SELECT Profile.Name FROM User` |
| `is_active` | boolean | Whether the user account is active |

Identity anchor for all salesperson-owned Salesforce objects.

---

### `salesforce_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `contacts_collected` | numeric | Rows collected for `salesforce_contacts` |
| `accounts_collected` | numeric | Rows collected for `salesforce_accounts` |
| `opportunities_collected` | numeric | Rows collected for `salesforce_opportunities` |
| `activities_collected` | numeric | Rows collected for `salesforce_activities` |
| `users_collected` | numeric | Rows collected for `salesforce_users` |
| `api_calls` | numeric | API / SOQL queries made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (instance URL, object types, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`salesforce_users.email` is the identity key for internal users (salespeople) — resolved to canonical `person_id` via Identity Manager.

`owner_id` (18-char Salesforce ID) is used to join activities, opportunities, and accounts back to `salesforce_users` for email resolution.

`salesforce_contacts.email` is for external customers — not resolved to `person_id` (same boundary as HubSpot contacts).

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `salesforce_users` | Identity Manager (email → `person_id`) | ✓ Used for identity resolution |
| `salesforce_opportunities` | `class_crm_deals` | Planned — CRM Silver stream not yet defined |
| `salesforce_activities` | `class_crm_activities` | Planned — CRM Silver stream not yet defined |
| `salesforce_contacts` | *(CRM reference)* | Available — external contacts, no Silver target |
| `salesforce_accounts` | *(CRM reference)* | Available — account data, no Silver target |

**Gold**: Same as HubSpot — sales performance metrics, deal pipeline analytics, workload per salesperson. The unified `class_crm_deals` and `class_crm_activities` streams will cover both HubSpot and Salesforce.

---

## Open Questions

### OQ-SF-1: Tasks vs Events — unified or separate Silver tables

Salesforce stores Tasks and Events as separate objects with different fields (Tasks have `status`, Events have `duration`). This spec merges them into `salesforce_activities` with nullable fields.

When building `class_crm_activities`:
- Should Tasks and Events be separate rows with nullable columns (this spec's approach)?
- Or should the Silver schema have `activity_subtype: task | event` with fully nullable non-universal fields?
- How does this map to HubSpot's unified engagement model?

### OQ-SF-2: Custom `__c` fields — collection scope

Salesforce customers heavily customise their schema with `__c` (custom) fields. The connector as specced collects standard fields only.

- Should whitelisted custom fields be collected (e.g. `Account.Contract_Value__c`)?
- If yes, should custom fields be stored in a `jsonb` catch-all column or as explicit columns per client configuration?

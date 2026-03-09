# HubSpot Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 16 (HubSpot)

Standalone specification for the HubSpot (CRM) connector. Expands Source 16 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`hubspot_contacts` — Person records](#hubspotcontacts-person-records)
  - [`hubspot_companies` — Company / account records](#hubspotcompanies-company-account-records)
  - [`hubspot_deals` — Deal pipeline records](#hubspotdeals-deal-pipeline-records)
  - [`hubspot_activities` — Calls, emails, meetings, tasks](#hubspotactivities-calls-emails-meetings-tasks)
  - [`hubspot_owners` — HubSpot user directory (salespeople)](#hubspotowners-hubspot-user-directory-salespeople)
  - [`hubspot_collection_runs` — Connector execution log](#hubspotcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-HS-1: HubSpot contacts vs internal employees — identity boundary](#oq-hs-1-hubspot-contacts-vs-internal-employees-identity-boundary)
  - [OQ-HS-2: CRM Silver stream design](#oq-hs-2-crm-silver-stream-design)

<!-- /toc -->

---

## Overview

**API**: HubSpot REST API v3

**Category**: CRM

**Authentication**: Private App token (HubSpot)

**Identity**: `hubspot_owners.email` — internal salespeople resolved to canonical `person_id` via Identity Manager. `hubspot_contacts.email` is for external customers — typically not resolved to `person_id`.

**Field naming**: snake_case — HubSpot API uses camelCase but normalised to snake_case at Bronze level.

**Why multiple tables**: HubSpot's object model is modular — contacts, companies, deals, and activities are separate endpoints joined by associations. Merging would require a wide denormalized table with many NULLs for inapplicable fields.

**Primary use in Insight**: linking commercial activity (deals, calls, meetings) to team members (`hubspot_owners`) for workload and sales performance analytics. `hubspot_contacts` and `hubspot_companies` are CRM objects — not internal employee records.

---

## Bronze Tables

### `hubspot_contacts` — Person records

| Field | Type | Description |
|-------|------|-------------|
| `contact_id` | text | HubSpot internal contact ID (`id` in API response) |
| `email` | text | Primary email — CRM contact email (external customer) |
| `first_name` | text | First name (`firstname` property) |
| `last_name` | text | Last name (`lastname` property) |
| `phone` | text | Primary phone number |
| `job_title` | text | Job title (`jobtitle` property) |
| `owner_id` | text | HubSpot owner (salesperson) ID (`hubspot_owner_id` property) — joins to `hubspot_owners.owner_id` |
| `lifecycle_stage` | text | `subscriber` / `lead` / `opportunity` / `customer` / etc. |
| `created_at` | timestamptz | Record creation (`createdate` property) |
| `updated_at` | timestamptz | Last update (`lastmodifieddate` property) — cursor for incremental sync |

**Note**: Contact–company association is not a direct property — collected via `/crm/v3/objects/contacts/{id}/associations/companies` and stored in `hubspot_associations`.

---

### `hubspot_companies` — Company / account records

| Field | Type | Description |
|-------|------|-------------|
| `company_id` | text | HubSpot internal company ID |
| `name` | text | Company name |
| `domain` | text | Website domain |
| `industry` | text | Industry classification |
| `owner_id` | text | Account owner ID — joins to `hubspot_owners.owner_id` |
| `created_at` | timestamptz | Record creation |
| `updated_at` | timestamptz | Last update |

---

### `hubspot_deals` — Deal pipeline records

| Field | Type | Description |
|-------|------|-------------|
| `deal_id` | text | HubSpot internal deal ID |
| `deal_name` | text | Deal name (`dealname` property) |
| `pipeline` | text | Pipeline internal name (`pipeline` property) |
| `stage` | text | Current stage internal name (`dealstage`), e.g. `appointmentscheduled` / `closedwon` / `closedlost` — portal-specific values |
| `amount` | numeric | Deal amount |
| `close_date` | date | Expected or actual close date (`closedate`) |
| `owner_id` | text | Deal owner ID (`hubspot_owner_id`) — joins to `hubspot_owners.owner_id` |
| `created_at` | timestamptz | Deal creation (`createdate`) |
| `updated_at` | timestamptz | Last update (`hs_lastmodifieddate`) — cursor for incremental sync |

**Note**: `is_won` / `is_closed` are not HubSpot deal properties — derived in Silver by comparing `stage` against closed stages from pipeline settings (`GET /crm/v3/pipelines/deals`).

**Note**: Deal–company and deal–contact links are Associations — collected via `/crm/v3/objects/deals/{id}/associations/companies` and stored in `hubspot_associations`.

---

### `hubspot_activities` — Calls, emails, meetings, tasks

Collected from separate v3 endpoints per type (`/crm/v3/objects/calls`, `/meetings`, `/emails`, `/tasks`, `/notes`) and merged with `activity_type` discriminator.

| Field | Type | Description |
|-------|------|-------------|
| `activity_id` | text | HubSpot object ID |
| `activity_type` | text | `call` / `email` / `meeting` / `task` / `note` |
| `owner_id` | text | Activity owner (`hubspot_owner_id` property) — joins to `hubspot_owners.owner_id` |
| `contact_id` | text | Associated contact ID (from associations; nullable) |
| `deal_id` | text | Associated deal ID (from associations; nullable) |
| `timestamp` | timestamptz | When the activity occurred (`hs_timestamp` property) |
| `duration_ms` | numeric | Duration in **milliseconds** (`hs_call_duration` for calls; NULL for other types) |
| `call_disposition_id` | text | Call outcome GUID (`hs_call_disposition`) — resolve to label via `GET /crm/v3/objects/call-dispositions`; NULL for non-calls |
| `meeting_outcome` | text | Meeting status (`hs_meeting_outcome`): `SCHEDULED` / `COMPLETED` / `NO_SHOW` / etc.; NULL for non-meetings |
| `created_at` | timestamptz | Record creation |

**Note**: `duration_ms` is in milliseconds — convert to seconds in Silver layer. Meeting duration is derived from `hs_meeting_start_time` and `hs_meeting_end_time` if `duration_ms` is NULL.

**Note**: Associated contacts and deals are collected via Associations API and joined at collection time.

---

### `hubspot_associations` — Object relationship links

HubSpot stores relationships between objects (contacts↔companies, deals↔contacts, deals↔companies) as Associations — not as direct properties. Collected via `/crm/v3/objects/{objectType}/{id}/associations/{toObjectType}`.

| Field | Type | Description |
|-------|------|-------------|
| `from_object_type` | text | Source object type: `deal` / `contact` / `company` |
| `from_object_id` | text | Source object ID |
| `to_object_type` | text | Target object type: `deal` / `contact` / `company` |
| `to_object_id` | text | Target object ID |
| `collected_at` | timestamptz | Collection timestamp |

---

### `hubspot_owners` — HubSpot user directory (salespeople)

| Field | Type | Description |
|-------|------|-------------|
| `owner_id` | text | HubSpot owner ID — joins to `owner_id` in other tables |
| `email` | text | Owner email — identity resolution key for internal salespeople |
| `first_name` | text | First name |
| `last_name` | text | Last name |
| `archived` | boolean | Whether the owner account is deactivated |

Identity anchor for all salesperson-owned CRM objects.

---

### `hubspot_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `contacts_collected` | numeric | Rows collected for `hubspot_contacts` |
| `companies_collected` | numeric | Rows collected for `hubspot_companies` |
| `deals_collected` | numeric | Rows collected for `hubspot_deals` |
| `activities_collected` | numeric | Rows collected for `hubspot_activities` |
| `owners_collected` | numeric | Rows collected for `hubspot_owners` |
| `api_calls` | numeric | API calls made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (portal, object types, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`hubspot_owners.email` is the identity key for internal users (salespeople) — resolved to canonical `person_id` via Identity Manager. This enables joining CRM activity to HR, git, and task tracker data via `person_id`.

`hubspot_contacts.email` is for external customers — typically **not** resolved to `person_id` unless the customer is also an internal employee (unusual edge case). CRM contacts are treated as external entities in Insight analytics.

`owner_id` (HubSpot numeric ID) is used to join activities, deals, and companies back to `hubspot_owners` for email resolution.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `hubspot_owners` | Identity Manager (email → `person_id`) | ✓ Used for identity resolution |
| `hubspot_deals` | `class_crm_deals` | Planned — CRM Silver stream not yet defined |
| `hubspot_activities` | `class_crm_activities` | Planned — CRM Silver stream not yet defined |
| `hubspot_contacts` | *(CRM reference)* | Available — external contacts, no Silver target |
| `hubspot_companies` | *(CRM reference)* | Available — account data, no Silver target |

**Gold**: Sales performance metrics (deal velocity, win rate, activity volume per salesperson), workload analytics (calls, meetings per owner), and pipeline health. Linked to `person_id` enables cross-domain joins with HR data (team, manager, department).

---

## Open Questions

### OQ-HS-1: HubSpot contacts vs internal employees — identity boundary

`hubspot_contacts` are external customer records. In some deployments, internal employees may be added as contacts (e.g. for internal project tracking). Should the Identity Manager attempt to resolve `hubspot_contacts.email` to `person_id`?

- Resolution: match `hubspot_contacts.email` against known internal emails and mark matched contacts as `is_internal = true`?
- Or treat all contacts as external and never resolve to `person_id`?

### OQ-HS-2: CRM Silver stream design

No `class_crm_deals` or `class_crm_activities` Silver stream is defined in `CONNECTORS_REFERENCE.md`. HubSpot and Salesforce represent the same domain:

- Should there be a unified `class_crm_deals` (HubSpot + Salesforce opportunities)?
- Should `class_crm_activities` unify HubSpot engagements with Salesforce Tasks + Events?
- What is the minimum common schema across the two CRM systems?

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
  - [`hubspot_associations` — Object relationship links](#hubspot_associations--object-relationship-links)
  - [`hubspot_contact_ext` — Custom contact properties (key-value)](#hubspot_contact_ext--custom-contact-properties-key-value)
  - [`hubspot_deal_ext` — Custom deal properties (key-value)](#hubspot_deal_ext--custom-deal-properties-key-value)
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
| `contact_id` | String | HubSpot internal contact ID (`id` in API response) |
| `email` | String | Primary email — CRM contact email (external customer) |
| `first_name` | String | First name (`firstname` property) |
| `last_name` | String | Last name (`lastname` property) |
| `phone` | String | Primary phone number |
| `job_title` | String | Job title (`jobtitle` property) |
| `owner_id` | String | HubSpot owner (salesperson) ID (`hubspot_owner_id` property) — joins to `hubspot_owners.owner_id` |
| `lifecycle_stage` | String | `subscriber` / `lead` / `opportunity` / `customer` / etc. |
| `created_at` | DateTime64(3) | Record creation (`createdate` property) |
| `updated_at` | DateTime64(3) | Last update (`lastmodifieddate` property) — cursor for incremental sync |

**Note**: Contact–company association is not a direct property — collected via `/crm/v3/objects/contacts/{id}/associations/companies` and stored in `hubspot_associations`.

---

### `hubspot_companies` — Company / account records

| Field | Type | Description |
|-------|------|-------------|
| `company_id` | String | HubSpot internal company ID |
| `name` | String | Company name |
| `domain` | String | Website domain |
| `industry` | String | Industry classification |
| `owner_id` | String | Account owner ID — joins to `hubspot_owners.owner_id` |
| `created_at` | DateTime64(3) | Record creation |
| `updated_at` | DateTime64(3) | Last update |

---

### `hubspot_deals` — Deal pipeline records

| Field | Type | Description |
|-------|------|-------------|
| `deal_id` | String | HubSpot internal deal ID |
| `deal_name` | String | Deal name (`dealname` property) |
| `pipeline` | String | Pipeline internal name (`pipeline` property) |
| `stage` | String | Current stage internal name (`dealstage`), e.g. `appointmentscheduled` / `closedwon` / `closedlost` — portal-specific values |
| `amount` | Float64 | Deal amount |
| `close_date` | Date | Expected or actual close date (`closedate`) |
| `owner_id` | String | Deal owner ID (`hubspot_owner_id`) — joins to `hubspot_owners.owner_id` |
| `created_at` | DateTime64(3) | Deal creation (`createdate`) |
| `updated_at` | DateTime64(3) | Last update (`hs_lastmodifieddate`) — cursor for incremental sync |

**Note**: `is_won` / `is_closed` are not HubSpot deal properties — derived in Silver by comparing `stage` against closed stages from pipeline settings (`GET /crm/v3/pipelines/deals`).

**Note**: Deal–company and deal–contact links are Associations — collected via `/crm/v3/objects/deals/{id}/associations/companies` and stored in `hubspot_associations`.

---

### `hubspot_activities` — Calls, emails, meetings, tasks

Collected from separate v3 endpoints per type (`/crm/v3/objects/calls`, `/meetings`, `/emails`, `/tasks`, `/notes`) and merged with `activity_type` discriminator.

| Field | Type | Description |
|-------|------|-------------|
| `activity_id` | String | HubSpot object ID |
| `activity_type` | String | `call` / `email` / `meeting` / `task` / `note` |
| `owner_id` | String | Activity owner (`hubspot_owner_id` property) — joins to `hubspot_owners.owner_id` |
| `contact_id` | String | Associated contact ID (from associations; nullable) |
| `deal_id` | String | Associated deal ID (from associations; nullable) |
| `timestamp` | DateTime64(3) | When the activity occurred (`hs_timestamp` property) |
| `duration_ms` | Float64 | Duration in **milliseconds** (`hs_call_duration` for calls; NULL for other types) |
| `call_disposition_id` | String | Call outcome GUID (`hs_call_disposition`) — resolve to label via `GET /crm/v3/objects/call-dispositions`; NULL for non-calls |
| `meeting_outcome` | String | Meeting status (`hs_meeting_outcome`): `SCHEDULED` / `COMPLETED` / `NO_SHOW` / etc.; NULL for non-meetings |
| `created_at` | DateTime64(3) | Record creation |

**Note**: `duration_ms` is in milliseconds — convert to seconds in Silver layer. Meeting duration is derived from `hs_meeting_start_time` and `hs_meeting_end_time` if `duration_ms` is NULL.

**Note**: Associated contacts and deals are collected via Associations API and joined at collection time.

---

### `hubspot_associations` — Object relationship links

HubSpot stores relationships between objects (contacts↔companies, deals↔contacts, deals↔companies) as Associations — not as direct properties. Collected via `/crm/v3/objects/{objectType}/{id}/associations/{toObjectType}`.

| Field | Type | Description |
|-------|------|-------------|
| `from_object_type` | String | Source object type: `deal` / `contact` / `company` |
| `from_object_id` | String | Source object ID |
| `to_object_type` | String | Target object type: `deal` / `contact` / `company` |
| `to_object_id` | String | Target object ID |
| `collected_at` | DateTime64(3) | Collection timestamp |

---

### `hubspot_contact_ext` — Custom contact properties (key-value)

HubSpot contacts support unlimited custom properties. Collected via the properties list on the contact response — any property not in the core `hubspot_contacts` schema is written here.

| Field | Type | Description |
|-------|------|-------------|
| `contact_id` | String | Parent contact ID — joins to `hubspot_contacts.contact_id` |
| `field_id` | String | HubSpot property internal name (camelCase) |
| `field_name` | String | HubSpot property label |
| `field_value` | String | Property value as string |
| `value_type` | String | Type hint: `string` / `number` / `enumeration` / `date` / `json` |
| `collected_at` | DateTime64(3) | Collection timestamp |

---

### `hubspot_deal_ext` — Custom deal properties (key-value)

HubSpot deals support custom properties per portal. Collected from any non-core deal property in the API response.

| Field | Type | Description |
|-------|------|-------------|
| `deal_id` | String | Parent deal ID — joins to `hubspot_deals.deal_id` |
| `field_id` | String | HubSpot property internal name |
| `field_name` | String | HubSpot property label |
| `field_value` | String | Property value as string |
| `value_type` | String | Type hint: `string` / `number` / `enumeration` / `date` / `json` |
| `collected_at` | DateTime64(3) | Collection timestamp |

---

### `hubspot_owners` — HubSpot user directory (salespeople)

| Field | Type | Description |
|-------|------|-------------|
| `owner_id` | String | HubSpot owner ID — joins to `owner_id` in other tables |
| `email` | String | Owner email — identity resolution key for internal salespeople |
| `first_name` | String | First name |
| `last_name` | String | Last name |
| `archived` | Bool | Whether the owner account is deactivated |

Identity anchor for all salesperson-owned CRM objects.

---

### `hubspot_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier |
| `started_at` | DateTime64(3) | Run start time |
| `completed_at` | DateTime64(3) | Run end time |
| `status` | String | `running` / `completed` / `failed` |
| `contacts_collected` | Float64 | Rows collected for `hubspot_contacts` |
| `companies_collected` | Float64 | Rows collected for `hubspot_companies` |
| `deals_collected` | Float64 | Rows collected for `hubspot_deals` |
| `activities_collected` | Float64 | Rows collected for `hubspot_activities` |
| `owners_collected` | Float64 | Rows collected for `hubspot_owners` |
| `api_calls` | Float64 | API calls made |
| `errors` | Float64 | Errors encountered |
| `settings` | String | Collection configuration (portal, object types, lookback) |

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

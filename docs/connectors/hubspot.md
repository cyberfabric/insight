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
| `contact_id` | text | HubSpot internal contact ID |
| `email` | text | Primary email — CRM contact email (external customer) |
| `first_name` | text | First name |
| `last_name` | text | Last name |
| `job_title` | text | Job title |
| `company_id` | text | Associated company ID — joins to `hubspot_companies.company_id` |
| `owner_id` | text | HubSpot owner (salesperson) ID — joins to `hubspot_owners.owner_id` |
| `lifecycle_stage` | text | `subscriber` / `lead` / `opportunity` / `customer` / etc. |
| `created_at` | timestamptz | Record creation |
| `updated_at` | timestamptz | Last update — cursor for incremental sync |

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
| `deal_name` | text | Deal name |
| `pipeline` | text | Pipeline name |
| `stage` | text | Current deal stage, e.g. `appointmentscheduled` / `closedwon` / `closedlost` |
| `amount` | numeric | Deal amount |
| `close_date` | date | Expected or actual close date |
| `owner_id` | text | Deal owner (salesperson) ID — joins to `hubspot_owners.owner_id` |
| `company_id` | text | Associated company |
| `contact_id` | text | Associated primary contact |
| `created_at` | timestamptz | Deal creation |
| `updated_at` | timestamptz | Last update |

---

### `hubspot_activities` — Calls, emails, meetings, tasks

| Field | Type | Description |
|-------|------|-------------|
| `activity_id` | text | HubSpot engagement ID |
| `activity_type` | text | `call` / `email` / `meeting` / `task` / `note` |
| `owner_id` | text | Activity owner (who performed it) — joins to `hubspot_owners.owner_id` |
| `contact_id` | text | Associated contact (nullable) |
| `deal_id` | text | Associated deal (nullable) |
| `timestamp` | timestamptz | When the activity occurred |
| `duration_seconds` | numeric | Duration (calls and meetings) |
| `outcome` | text | Call outcome or meeting status (source-specific values) |
| `created_at` | timestamptz | Record creation |

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

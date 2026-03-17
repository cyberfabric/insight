# Workday Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 11 (Workday)

Standalone specification for the Workday (HR) connector. Expands Source 11 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`workday_workers` — Worker records (point-in-time)](#workdayworkers-worker-records-point-in-time)
  - [`workday_organizations` — Org units (departments, supervisory orgs, cost centers)](#workdayorganizations-org-units-departments-supervisory-orgs-cost-centers)
  - [`workday_leave` — Leave of absence and time off](#workdayleave-leave-of-absence-and-time-off)
  - [`workday_worker_ext` — Custom worker fields (key-value)](#workday_worker_ext--custom-worker-fields-key-value)
  - [`workday_collection_runs` — Connector execution log](#workdaycollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-WD-1: Effective dating strategy — full snapshot vs delta](#oq-wd-1-effective-dating-strategy-full-snapshot-vs-delta)
  - [OQ-WD-2: BambooHR + Workday coexistence](#oq-wd-2-bamboohr-workday-coexistence)

<!-- /toc -->

---

## Overview

**API**: Workday REST API (Workday RaaS — Reports-as-a-Service) or Workday SOAP/WSDL API

**Category**: HR / Directory

**Authentication**: ISU (Integration System User) credentials — Workday integration service account

**Identity**: `workday_workers.email` — resolved to canonical `person_id` via Identity Manager. HR connectors feed the Identity Manager directly alongside their Bronze tables.

**Field naming**: snake_case — Workday API uses mixed formats; normalised to snake_case at Bronze level.

**Why multiple tables**: Workers, org units, and leave are distinct entities. The supervisory org structure is a separate entity tree (`workday_organizations`) that workers reference — storing org details inline in the worker record would denormalize all org changes.

**Key differences from BambooHR:**

| Aspect | BambooHR | Workday |
|--------|----------|---------|
| Record versioning | Current state only | Effective-dated point-in-time snapshots |
| Worker types | Employee + Contractor (freeform) | `Employee` / `Contingent_Worker` (explicit enum) |
| Org model | Department name (freeform string) | Supervisory Organization (separate entity with hierarchy) |
| Position model | Not tracked | `position_id` (job slot) is separate from the person |
| Scale | SMB (100–5000 employees) | Enterprise (5000+ employees) |

**Primary use in Insight**: identity resolution, historical org structure for time-series team analytics, leave history with full categorisation.

---

## Bronze Tables

### `workday_workers` — Worker records (point-in-time)

| Field | Type | Description |
|-------|------|-------------|
| `worker_id` | String | Workday internal worker ID |
| `email` | String | Work email — primary key for cross-system identity resolution |
| `full_name` | String | Display name |
| `first_name` | String | First name |
| `last_name` | String | Last name |
| `worker_type` | String | `Employee` / `Contingent_Worker` |
| `employment_status` | String | `Active` / `Terminated` / `Leave` |
| `job_title` | String | Business title |
| `job_profile` | String | Standardized job profile name |
| `position_id` | String | Position (job slot) identifier |
| `supervisory_org_id` | String | Supervisory organization ID — defines the reporting chain; joins to `workday_organizations.org_id` |
| `supervisory_org_name` | String | Supervisory organization name |
| `department` | String | Department name |
| `cost_center_id` | String | Cost center ID |
| `cost_center_name` | String | Cost center name |
| `manager_id` | String | Manager's Workday worker ID |
| `manager_email` | String | Manager's email |
| `location` | String | Office or `Remote` |
| `hire_date` | Date | Employment start date |
| `termination_date` | Date | Employment end date (NULL if active) |
| `effective_date` | Date | Date from which this record version is valid |

`effective_date` makes this a point-in-time snapshot. Multiple rows per worker are expected — each org change produces a new versioned row.

---

### `workday_organizations` — Org units (departments, supervisory orgs, cost centers)

| Field | Type | Description |
|-------|------|-------------|
| `org_id` | String | Workday org unit ID — primary key |
| `org_type` | String | `Supervisory` / `Department` / `CostCenter` / `Company` |
| `name` | String | Org unit name |
| `parent_org_id` | String | Parent org unit ID (NULL for root) |
| `head_worker_id` | String | Org head's Workday worker ID |
| `effective_date` | Date | Date from which this org version is valid |

Org units are also effective-dated — a department rename or restructure produces a new versioned row.

---

### `workday_leave` — Leave of absence and time off

| Field | Type | Description |
|-------|------|-------------|
| `leave_id` | String | Workday leave request ID — primary key |
| `worker_id` | String | Worker's Workday ID — joins to `workday_workers.worker_id` |
| `worker_email` | String | Worker email |
| `leave_category` | String | `Leave_of_Absence` / `Time_Off` |
| `leave_type` | String | e.g. `Vacation`, `Sick`, `Parental`, `FMLA` (policy-defined) |
| `start_date` | Date | Leave start |
| `end_date` | Date | Leave end |
| `duration_days` | Float64 | Working days absent |
| `status` | String | `Approved` / `Pending` / `Cancelled` |
| `created_at` | DateTime64(3) | When the request was submitted |

`leave_category` is Workday-specific (high-level), while `leave_type` is policy-defined and client-specific.

---

### `workday_worker_ext` — Custom worker fields (key-value)

Workday workers support custom integration fields via custom reports (RaaS — Reports-as-a-Service) or integration system fields. Any field not in the core `workday_workers` schema — including custom integration attributes and calculated fields from custom reports — is written here.

**Note**: Like BambooHR, Workday exposes custom fields inline in the worker response (or via a custom RaaS report that includes extra columns). This table captures those fields in the standard key-value pattern. `class_people.custom_str_attrs` and `class_people.custom_num_attrs` are populated from these values at Silver processing time.

| Field | Type | Description |
|-------|------|-------------|
| `employee_id` | String | Parent worker ID — joins to `workday_workers.worker_id` |
| `field_id` | String | Workday field or report column ID, e.g. `Custom_Attribute_1` |
| `field_name` | String | Field display name (from RaaS report column header or field metadata) |
| `field_value` | String | Field value as string |
| `value_type` | String | Type hint: `string` / `number` / `date` / `json` |
| `collected_at` | DateTime64(3) | Collection timestamp |

**Discovery**: custom fields are defined in the Workday RaaS report configuration or Integration System configuration. The connector administrator must declare which custom report columns to collect via the connector configuration.

---

### `workday_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier |
| `started_at` | DateTime64(3) | Run start time |
| `completed_at` | DateTime64(3) | Run end time |
| `status` | String | `running` / `completed` / `failed` |
| `workers_collected` | Float64 | Rows collected for `workday_workers` |
| `organizations_collected` | Float64 | Rows collected for `workday_organizations` |
| `leave_records_collected` | Float64 | Rows collected for `workday_leave` |
| `api_calls` | Float64 | API calls made |
| `errors` | Float64 | Errors encountered |
| `settings` | String | Collection configuration (tenant, RaaS report URLs, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`workday_workers.email` is the primary identity key — mapped to canonical `person_id` via Identity Manager. HR connectors feed the Identity Manager directly as part of Bronze ingestion.

`worker_id` (Workday internal worker ID) is Workday-internal — not used for cross-system resolution.

`manager_email` enables org hierarchy construction from email addresses without requiring `worker_id` resolution. The `supervisory_org_id` provides an additional hierarchy path via `workday_organizations`.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `workday_workers` | Identity Manager (email → `person_id`) | ✓ Feeds identity resolution directly |
| `workday_workers` | `class_people` | Planned — HR unified stream not yet defined |
| `workday_organizations` | *(reference table)* | Available — no unified stream defined yet |
| `workday_leave` | `class_people` | Leave periods captured as `status = 'on_leave'` transitions in SCD2 |

**Gold**: Historical org structure (team composition over time), leave analytics (burnout risk, availability), and headcount metrics. Effective dating in `workday_workers` enables point-in-time queries — "what was the team composition in Q3 2025?" — which is not possible with BambooHR.

---

## Open Questions

### OQ-WD-1: Effective dating strategy — full snapshot vs delta

Workday records are effective-dated (multiple versions per worker). The connector can collect:

- **Full snapshot**: all effective-dated records on every run (expensive, complete)
- **Delta**: only records with `effective_date >= last_run_date` (efficient, may miss retroactive changes)

- Which collection strategy is used?
- Are retroactive effective date changes (back-dated org moves) expected in the client data?

### OQ-WD-2: BambooHR + Workday coexistence

Some clients may use both BambooHR and Workday (e.g. Workday for enterprise HR, BambooHR for a subsidiary). When both HR sources are active:

- Does the Identity Manager merge them by email?
- Which source takes precedence for org hierarchy (manager chain)?
- Should `class_people` carry a `source` field indicating which HR system is authoritative per person?

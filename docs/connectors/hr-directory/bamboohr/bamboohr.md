# BambooHR Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 10 (BambooHR)

Standalone specification for the BambooHR (HR) connector. Expands Source 10 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`bamboohr_employees` — Employee records](#bamboohremployees-employee-records)
  - [`bamboohr_departments` — Department hierarchy](#bamboohrdepartments-department-hierarchy)
  - [`bamboohr_leave_requests` — Time off requests](#bamboohrleaverequests-time-off-requests)
  - [`bamboohr_employee_ext` — Custom employee fields (key-value)](#bamboohr_employee_ext--custom-employee-fields-key-value)
  - [`bamboohr_collection_runs` — Connector execution log](#bamboohrcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-BHR-1: Current-state records — how to track historical org changes](#oq-bhr-1-current-state-records-how-to-track-historical-org-changes)
  - [OQ-BHR-2: Leave type normalisation across HR systems](#oq-bhr-2-leave-type-normalisation-across-hr-systems)

<!-- /toc -->

---

## Overview

**API**: BambooHR REST API v1

**Category**: HR / Directory

**Authentication**: API key (BambooHR company account)

**Identity**: `bamboohr_employees.email` — resolved to canonical `person_id` via Identity Manager. HR connectors feed the Identity Manager directly alongside their Bronze tables.

**Field naming**: snake_case — BambooHR API uses camelCase but renamed to snake_case at Bronze level for consistency with other HR connectors.

**Why multiple tables**: Employees, departments, and leave requests are distinct entities with 1:N relationships (one department has many employees; one employee has many leave requests). Merging would denormalize department metadata onto every employee row and repeat employee metadata on every leave row.

**SMB-focused design**: BambooHR returns current-state records only — no effective dating, no versioning. This is fundamentally different from Workday (which versions all records). Historical org structure cannot be reconstructed from BambooHR Bronze alone.

**Primary use in Insight**: identity resolution (canonical email + manager chain), org hierarchy for team-level aggregation, leave history for burnout risk and availability signals.

---

## Bronze Tables

### `bamboohr_employees` — Employee records

| Field | Type | Description |
|-------|------|-------------|
| `employee_id` | String | BambooHR internal numeric ID |
| `email` | String | Work email — primary key for cross-system identity resolution |
| `full_name` | String | Display name |
| `first_name` | String | First name |
| `last_name` | String | Last name |
| `department` | String | Department name |
| `department_id` | String | Department ID — joins to `bamboohr_departments.department_id` |
| `job_title` | String | Job title (freeform string — not normalised) |
| `employment_type` | String | `Full-Time` / `Part-Time` / `Contractor` |
| `status` | String | `Active` / `Terminated` |
| `manager_id` | String | Manager's BambooHR employee ID |
| `manager_email` | String | Manager's email — used to build org hierarchy |
| `location` | String | Office location or `Remote` |
| `hire_date` | Date | Employment start date |
| `termination_date` | Date | Employment end date (NULL if active) |

Current-state only — no effective dating. The connector overwrites rows on each run; historical snapshots are not preserved at Bronze level.

---

### `bamboohr_departments` — Department hierarchy

| Field | Type | Description |
|-------|------|-------------|
| `department_id` | String | BambooHR department ID — primary key |
| `name` | String | Department name |
| `parent_department_id` | String | Parent department ID (NULL for root) |

Enables hierarchical org traversal — a team can be nested under multiple layers of departments.

---

### `bamboohr_leave_requests` — Time off requests

| Field | Type | Description |
|-------|------|-------------|
| `request_id` | String | BambooHR request ID — primary key |
| `employee_id` | String | Employee's BambooHR ID — joins to `bamboohr_employees.employee_id` |
| `employee_email` | String | Employee email |
| `leave_type` | String | `Vacation` / `Sick` / `Parental` / `Unpaid` / etc. (freeform — client-configured) |
| `start_date` | Date | Leave start |
| `end_date` | Date | Leave end |
| `duration_days` | Float64 | Working days absent |
| `status` | String | `approved` / `pending` / `cancelled` |
| `created_at` | DateTime64(3) | When the request was submitted |

`leave_type` values are freeform and client-configured — normalisation across BambooHR and Workday requires a mapping layer at Silver or Gold.

---

### `bamboohr_employee_ext` — Custom employee fields (key-value)

BambooHR returns all custom fields in the main employee response if included in the fields list when calling `GET /api/gateway.php/{company}/v1/employees/{id}`. Custom fields have IDs like `customField1`, `customField2`, etc. Any field not in the core `bamboohr_employees` schema is written here.

**Note**: Unlike most other connectors, there is no separate Bronze `_ext` table required — BambooHR exposes custom fields inline in the main employee response. This table captures those fields in the standard key-value pattern for consistency. `class_people.custom_str_attrs` and `class_people.custom_num_attrs` are populated directly from these values at Silver processing time.

| Field | Type | Description |
|-------|------|-------------|
| `employee_id` | String | Parent employee ID — joins to `bamboohr_employees.employee_id` |
| `field_id` | String | BambooHR custom field ID, e.g. `customField1`, `customField5` |
| `field_name` | String | Custom field display name (from field metadata API) |
| `field_value` | String | Field value as string |
| `value_type` | String | Type hint: `string` / `number` / `date` / `json` |
| `collected_at` | DateTime64(3) | Collection timestamp |

**Discovery**: `GET /api/gateway.php/{company}/v1/meta/fields` returns all available field IDs and their display names, including custom fields.

---

### `bamboohr_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier |
| `started_at` | DateTime64(3) | Run start time |
| `completed_at` | DateTime64(3) | Run end time |
| `status` | String | `running` / `completed` / `failed` |
| `employees_collected` | Float64 | Rows collected for `bamboohr_employees` |
| `departments_collected` | Float64 | Rows collected for `bamboohr_departments` |
| `leave_requests_collected` | Float64 | Rows collected for `bamboohr_leave_requests` |
| `api_calls` | Float64 | API calls made |
| `errors` | Float64 | Errors encountered |
| `settings` | String | Collection configuration (subdomain, field selection, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`bamboohr_employees.email` is the primary identity key — mapped to canonical `person_id` via Identity Manager. Unlike analytical connectors that only feed Silver step 2, HR connectors feed the Identity Manager directly as part of Bronze ingestion.

`employee_id` (BambooHR internal numeric ID) and `manager_id` are BambooHR-internal — not used for cross-system resolution.

`manager_email` enables building the org hierarchy from email addresses alone, without resolving manager IDs to `person_id` first. This is the recommended approach for org tree construction.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `bamboohr_employees` | Identity Manager (email → `person_id`) | ✓ Feeds identity resolution directly |
| `bamboohr_employees` | `class_people` | Planned — HR unified stream not yet defined |
| `bamboohr_departments` | *(reference table)* | Available — no unified stream defined yet |
| `bamboohr_leave_requests` | `class_people` | Leave periods captured as `status = 'on_leave'` transitions in SCD2 |

**Gold**: Org hierarchy (team-level metric aggregation), leave analytics (burnout risk, availability), and headcount metrics will derive from a future HR Silver layer once `class_people` is defined.

---

## Open Questions

### OQ-BHR-1: Current-state records — how to track historical org changes

BambooHR returns only current-state records — no effective dating. If a person moves from Engineering to Marketing, the Bronze record is overwritten.

- Should the collector snapshot `bamboohr_employees` daily (creating a `collected_at`-versioned audit table)?
- Or is current-state sufficient for Insight use cases (org hierarchy is only needed at query time, not historically)?

### OQ-BHR-2: Leave type normalisation across HR systems

`bamboohr_leave_requests.leave_type` is freeform (client-configured). `workday_leave.leave_type` is policy-defined but also client-specific.

- Should Silver define a normalised `leave_category` enum (`vacation` / `sick` / `parental` / `other`) and map source values via config?
- Or is leave type kept raw in Silver and only normalised at Gold?

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
| `employee_id` | text | BambooHR internal numeric ID |
| `email` | text | Work email — primary key for cross-system identity resolution |
| `full_name` | text | Display name |
| `first_name` | text | First name |
| `last_name` | text | Last name |
| `department` | text | Department name |
| `department_id` | text | Department ID — joins to `bamboohr_departments.department_id` |
| `job_title` | text | Job title (freeform string — not normalised) |
| `employment_type` | text | `Full-Time` / `Part-Time` / `Contractor` |
| `status` | text | `Active` / `Terminated` |
| `manager_id` | text | Manager's BambooHR employee ID |
| `manager_email` | text | Manager's email — used to build org hierarchy |
| `location` | text | Office location or `Remote` |
| `hire_date` | date | Employment start date |
| `termination_date` | date | Employment end date (NULL if active) |

Current-state only — no effective dating. The connector overwrites rows on each run; historical snapshots are not preserved at Bronze level.

---

### `bamboohr_departments` — Department hierarchy

| Field | Type | Description |
|-------|------|-------------|
| `department_id` | text | BambooHR department ID — primary key |
| `name` | text | Department name |
| `parent_department_id` | text | Parent department ID (NULL for root) |

Enables hierarchical org traversal — a team can be nested under multiple layers of departments.

---

### `bamboohr_leave_requests` — Time off requests

| Field | Type | Description |
|-------|------|-------------|
| `request_id` | text | BambooHR request ID — primary key |
| `employee_id` | text | Employee's BambooHR ID — joins to `bamboohr_employees.employee_id` |
| `employee_email` | text | Employee email |
| `leave_type` | text | `Vacation` / `Sick` / `Parental` / `Unpaid` / etc. (freeform — client-configured) |
| `start_date` | date | Leave start |
| `end_date` | date | Leave end |
| `duration_days` | numeric | Working days absent |
| `status` | text | `approved` / `pending` / `cancelled` |
| `created_at` | timestamptz | When the request was submitted |

`leave_type` values are freeform and client-configured — normalisation across BambooHR and Workday requires a mapping layer at Silver or Gold.

---

### `bamboohr_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `employees_collected` | numeric | Rows collected for `bamboohr_employees` |
| `departments_collected` | numeric | Rows collected for `bamboohr_departments` |
| `leave_requests_collected` | numeric | Rows collected for `bamboohr_leave_requests` |
| `api_calls` | numeric | API calls made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (subdomain, field selection, lookback) |

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
| `bamboohr_leave_requests` | `class_leave` | Planned — leave unified stream not yet defined |

**Gold**: Org hierarchy (team-level metric aggregation), leave analytics (burnout risk, availability), and headcount metrics will derive from a future HR Silver layer once `class_people` and `class_leave` streams are defined.

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

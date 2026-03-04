# LDAP / Active Directory Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 12 (LDAP / Active Directory)

Standalone specification for the LDAP / Active Directory (Directory) connector. Expands Source 12 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`ldap_users` — User account directory](#ldapusers-user-account-directory)
  - [`ldap_group_members` — Group and OU membership](#ldapgroupmembers-group-and-ou-membership)
  - [`ldap_collection_runs` — Connector execution log](#ldapcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-LDAP-1: OpenLDAP vs Active Directory field differences](#oq-ldap-1-openldap-vs-active-directory-field-differences)
  - [OQ-LDAP-2: Group hierarchy flattening strategy](#oq-ldap-2-group-hierarchy-flattening-strategy)

<!-- /toc -->

---

## Overview

**Protocol**: LDAP v3 (OpenLDAP or Microsoft Active Directory)

**Category**: HR / Directory

**Authentication**: Simple bind (service account DN + password) or SASL/Kerberos (AD)

**Identity**: `ldap_users.email` (`mail` attribute) — resolved to canonical `person_id` via Identity Manager.

**Field naming**: snake_case — LDAP attribute names (e.g. `sAMAccountName`, `givenName`) are normalised to snake_case at Bronze level.

**Why two tables**: Users and group memberships are distinct entities — a user can belong to many groups (many-to-many), and groups can be nested. Flattening would repeat group metadata on every user row and lose nested group information.

**Different model from HR systems**: LDAP is a hierarchical directory protocol — the primary record is a distinguished name (`dn`), not a numeric employee ID. LDAP is authoritative for account status (enabled/disabled) and login identities, not for employment records or compensation.

**Primary use in Insight**:
- Identity resolution: linking login accounts to email addresses
- Account lifecycle: join/leave detection via `account_disabled`
- Group membership: team segmentation from directory groups

---

## Bronze Tables

### `ldap_users` — User account directory

| Field | Type | Description |
|-------|------|-------------|
| `dn` | text | Distinguished name — unique identifier, e.g. `CN=John Smith,OU=Engineering,DC=corp,DC=example,DC=com` |
| `sam_account_name` | text | Windows login name (Active Directory) / `uid` in OpenLDAP |
| `email` | text | `mail` attribute — primary key for cross-system identity resolution |
| `full_name` | text | `cn` (common name) |
| `first_name` | text | `givenName` |
| `last_name` | text | `sn` (surname) |
| `department` | text | `department` attribute |
| `title` | text | `title` attribute |
| `manager_dn` | text | `manager` attribute — DN of the manager's LDAP record |
| `ou` | text | Organizational unit path |
| `account_disabled` | boolean | Whether the account is disabled |
| `last_logon` | timestamptz | Last successful login (Active Directory only — not available in OpenLDAP) |
| `created_at` | timestamptz | `whenCreated` — account provisioning date |
| `updated_at` | timestamptz | `whenChanged` — last directory update |

---

### `ldap_group_members` — Group and OU membership

| Field | Type | Description |
|-------|------|-------------|
| `group_dn` | text | Distinguished name of the group |
| `group_name` | text | `cn` of the group |
| `group_type` | text | `security` / `distribution` / `ou` |
| `member_dn` | text | DN of the member (user or nested group) |
| `member_email` | text | Resolved email of the member (NULL for nested groups) |
| `is_nested_group` | boolean | True if `member_dn` is itself a group |

Group membership is many-to-many. A user in `Engineering > Backend` appears in both the sub-group and all parent groups if the directory is structured hierarchically. `is_nested_group` allows downstream consumers to flatten the hierarchy.

---

### `ldap_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `users_collected` | numeric | Rows collected for `ldap_users` |
| `group_members_collected` | numeric | Rows collected for `ldap_group_members` |
| `api_calls` | numeric | LDAP search operations performed |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (server URL, base DN, search filters) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`ldap_users.email` (`mail` attribute) is the primary identity key — mapped to canonical `person_id` via Identity Manager.

`sam_account_name` (Windows login / uid) is a secondary identifier — useful for resolving git commit authors whose email is masked but whose login is visible (e.g. git commits with `username@corp.internal` that map to an AD `sAMAccountName`).

`dn` is the LDAP-internal primary key — not used for cross-system resolution.

`manager_dn` can be resolved to the manager's email by joining back to `ldap_users.dn`, enabling manager chain construction from LDAP alone without BambooHR/Workday.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `ldap_users` | Identity Manager (email → `person_id`) | ✓ Feeds identity resolution directly |
| `ldap_users` | `class_people` | Planned — HR unified stream not yet defined |
| `ldap_group_members` | *(reference table)* | Available — enables team segmentation at Gold |

**Gold**: Account lifecycle metrics (join/leave rates, orphaned accounts), team composition from directory groups. LDAP is typically the most up-to-date source for active/disabled account status — faster than HR system updates.

---

## Open Questions

### OQ-LDAP-1: OpenLDAP vs Active Directory field differences

`last_logon` is Active Directory-specific (`lastLogon` attribute). OpenLDAP does not have an equivalent.

- Should `last_logon` be NULL in the schema for OpenLDAP deployments, or should a separate flag indicate AD vs OpenLDAP mode?
- Are there other AD-specific fields that need conditional handling?

### OQ-LDAP-2: Group hierarchy flattening strategy

`ldap_group_members.is_nested_group` flags nested group entries. Downstream consumers may need the fully-flattened membership list (all effective members of a group, including members of nested sub-groups).

- Is flattening done at Bronze (fully expanded `ldap_group_members`) or at Silver/Gold query time?
- Fully-expanded membership can be expensive to compute for large directories with deep nesting.

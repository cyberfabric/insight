# PRD -- Identity Resolution

## 1. Overview

### 1.1 Purpose

Identity Resolution maps identity signals from all connected source systems (BambooHR, Zoom, GitLab, Jira, Slack, etc.) into unified person records. It is a human-in-the-loop system: connectors emit identity observations automatically, the system generates matching proposals, and operators confirm or reject them.

### 1.2 Background / Problem Statement

Insight connects to 10+ external platforms. Each platform has its own user model: BambooHR has employees with workEmail and employeeNumber, Zoom has users with email and display_name, GitLab has users with username and email. The same real person often appears in multiple systems with different identifiers and sometimes different field values (e.g., personal email in one system, corporate email in another).

**Key problems solved**:
- **No unified identity**: Without identity resolution, analytics queries cannot correlate activity across systems for the same person
- **Silent wrong merges**: Automated email-based matching produces false positives (shared mailboxes, name collisions). All matches must be operator-confirmed
- **No temporal awareness**: Employee turnover means email addresses get recycled. Aliases must have start/end dates
- **Irreversible merges**: If two profiles are wrongly merged, the system must support splitting them without losing historical data

### 1.3 Goals

| Goal | Success Criteria |
|---|---|
| Unified person identity | 100% of cross-system analytics queries use identity-resolved person_id |
| Zero false-positive merges | All alias-to-person assignments are operator-confirmed; no automatic linking |
| Temporal correctness | Person state queryable at any historical date; merge/split does not alter past data |
| Reversible operations | Any merge can be split; any link can be unlinked; history preserved |

### 1.4 Glossary

| Term | Definition |
|---|---|
| Source profile | A user account in an external system, identified by (source_type, profile_id) |
| Identity input | A single field observation from a source profile: (field_type, field_value, observed_at) |
| Proposal | A system-generated suggestion for the operator: new unlinked profile, email match, or deactivation |
| Link | An operator decision binding a source profile to a person_id, with a timestamp |
| Person | A unified identity, represented as a vertical history of fields from linked source profiles |
| Merge | Moving a source profile's link from one person to another |
| Split | Reversing a merge: moving a source profile's link back to its original person |
| Deactivation | A DELETE operation from a connector indicating a field is no longer valid (e.g., employee terminated) |

## 2. Actors

### 2.1 Human Actors

| Actor | Role |
|---|---|
| Platform Operator | Reviews proposals, creates/updates links, performs merge/split operations |
| Analytics Consumer | Queries person data via identity_person table; uses person_id in reports |

### 2.2 System Actors

| Actor | Role |
|---|---|
| Connectors (Airbyte + dbt) | Emit identity observations into staging.*__identity_input tables |
| dbt Pipeline | Generates proposals from identity_input; materializes identity_person from input + links |

## 3. Scope

### 3.1 In Scope

- Collection of identity field observations from all connectors (email, display_name, employee_id, username, platform_id)
- Automatic detection of cross-system matches (same email in different sources)
- Proposal generation for operator review
- Operator workflow: link, unlink, merge, split
- Temporal person field history (append-only, queryable at any date)
- Incremental processing (no full rebuilds)

### 3.2 Out of Scope

- Automatic alias creation (all aliases are operator-confirmed)
- Fuzzy matching / ML-based matching (future phase)
- Golden record assembly and source-priority rules (Person domain)
- Org hierarchy (Org-Chart domain)
- GDPR hard deletion (future phase)
- Batch approve UI (future phase; MVP is one-by-one via SQL)

## 4. Functional Requirements

### 4.1 Identity Input Collection (p1)

Each connector extracts identity-relevant fields (email, display_name, employee_id, username, platform_id) from its change history. Two operation types: UPSERT (field changed or set) and DELETE (field cleared or entity deactivated).

All connector inputs are unified into a single identity input stream.

### 4.2 Proposal Generation (p1)

The system generates matching proposals by comparing identity input data:
- **new_profile**: A source profile has no current person binding
- **email_match**: Two profiles from different source systems share the same current email address
- **deactivation**: A source system signals that an entity has been deactivated

Proposals are generated incrementally and deduplicated.

### 4.3 Operator Link Management (p1)

Operators bind source profiles to persons:
- **Create new person**: Assign a new person identity, bind a profile to it
- **Bind to existing person**: Bind a profile to an already-existing person
- **Unbind**: Remove a profile's binding to a person
- **Merge**: Move a profile binding from one person to another (unbind + bind)
- **Split**: Reverse of merge (unbind + bind back to original)

All operations are append-only and auditable.

### 4.4 Person Field Materialization (p1)

When bindings change or new input data arrives, person fields are updated:
- **Bind event**: Current field values from the bound profile are assigned to the person
- **Unbind event**: All fields the person had from that profile are cleared
- **New input data**: When a source syncs new data for an already-bound profile, the new values propagate to the person

### 4.5 Temporal Queries (p1)

Person state at any historical date is queryable. Merge/split operations do not alter past data -- they only add new records with later timestamps.

## 5. Non-Functional Requirements

| NFR | Target |
|---|---|
| Incremental processing | Each run processes only new data since last run |
| Idempotency | Repeated runs with no new data produce no new records |
| Append-only storage | No destructive operations on core tables |
| Query performance | Current person state query < 100ms for single person |

## 6. Dependencies

| Dependency | Description |
|---|---|
| Connector change history | Each connector must provide field-level change history for identity input extraction |
| Data warehouse | All tables stored in a columnar analytical database |
| Transformation pipeline | Incremental transformations for input processing, proposal generation, person materialization |
| Operator access | MVP: direct database access; future: UI |

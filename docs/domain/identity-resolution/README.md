# Identity Resolution Domain

Identity Resolution maps identity signals (emails, usernames, employee IDs, display names) from all connected source systems into unified person records. It operates as a human-in-the-loop system: connectors emit identity observations, the system generates matching proposals, and operators confirm or reject them.

## Documents

| Document | Description |
|---|---|
| [`specs/PRD.md`](specs/PRD.md) | Product requirements: identity input, proposals, operator workflow, merge/split |
| [`specs/DESIGN.md`](specs/DESIGN.md) | Technical design: three-table architecture, dbt models, data flow, DDL |

## Architecture

Three append-only vertical tables:

```
identity.identity_input    ← facts from connectors (automatic)
identity.links             ← operator decisions: profile -> person bindings
identity.identity_person   ← computed person fields (dbt, incremental)
```

Supporting:
```
identity.identity_proposals ← matching suggestions for operator (dbt, incremental)
```

## Data Flow

```
Connectors (Airbyte)
  -> bronze_*.* (raw data)
  -> staging.*_snapshot (SCD Type 2)
  -> staging.*_fields_history (vertical field changes)
  -> staging.*__identity_input (identity-relevant fields, per connector)
  -> identity.identity_input (VIEW, union of all connectors)
  -> identity.identity_proposals (matching suggestions)
  -> [operator reviews, creates links]
  -> identity.identity_person (person field history)
```

## How to resolve a person

### Given a source profile ID (e.g., BambooHR employee_id = "ST069")

```sql
-- Step 1: Find which person this profile is currently linked to
-- (latest action must be 'link', not 'unlink')
SELECT person_id, action
FROM identity.links
WHERE source_type = 'bamboohr'
  AND profile_id = '1002'  -- profile containing employee_id ST069
ORDER BY created_at DESC
LIMIT 1;
-- If action = 'link' → person_id is valid. If 'unlink' → profile is not linked.

-- Step 2: Get current person fields
SELECT
    field_type,
    field_source,
    argMax(field_value, valid_from) AS current_value
FROM identity.identity_person
WHERE person_id = '019d9753-...'
GROUP BY field_type, field_source
HAVING current_value != '';
```

Result:
```
field_type    field_source  current_value
email         bamboohr      Stefan.Radu@constructor.tech
email         zoom          stefan.radu@constructor.tech
display_name  bamboohr      Daniel Stefan Radu
display_name  zoom          Daniel Stefan Radu
employee_id   bamboohr      ST069
employee_id   zoom          bl71mPn2Rem9b3w4NzM-qQ
```

### Given a person_id, get all linked profiles

```sql
-- Current active links for a person
SELECT source_type, profile_id, created_at
FROM (
    SELECT *,
        row_number() OVER (
            PARTITION BY insight_tenant_id, source_type, profile_id
            ORDER BY created_at DESC
        ) AS rn
    FROM identity.links
    WHERE person_id = '019d9753-...'
)
WHERE rn = 1 AND action = 'link' AND profile_id IS NOT NULL;
```

Result:
```
source_type  profile_id              created_at
bamboohr     1002                    2026-04-16 17:25:22
zoom         bl71mPn2Rem9b3w4NzM-qQ 2026-04-16 17:25:23
```

### Given a field value (e.g., email), find the person

```sql
-- Find person by email across all sources
SELECT DISTINCT person_id
FROM identity.identity_person
WHERE field_type = 'email'
  AND lower(field_value) = 'stefan.radu@constructor.tech'
  AND field_value != '';  -- exclude nullified entries
```

### Person state at a specific date

```sql
-- Person fields as of 2026-04-15
SELECT
    field_type,
    field_source,
    argMax(field_value, valid_from) AS value_at_date
FROM identity.identity_person
WHERE person_id = '019d9753-...'
  AND valid_from <= '2026-04-15'
GROUP BY field_type, field_source
HAVING value_at_date != '';
```

## Operator Workflow

### 1. Review proposals

```sql
SELECT proposal_type, source_type, profile_id, field_type, field_value,
       matched_source_type, matched_profile_id, match_reason
FROM identity.identity_proposals
WHERE status = 'pending'
ORDER BY proposal_type, source_type;
```

### 2. Create a new person from an unlinked profile

```sql
INSERT INTO identity.links
    (insight_tenant_id, person_id, source_type, profile_id, action, reason, created_by)
VALUES
    ('example_tenant', generateUUIDv7(), 'bamboohr', '1002', 'link', 'new_person', 'operator_name');
```

### 3. Link another profile to an existing person

```sql
-- First, find the person_id from step 2
INSERT INTO identity.links
    (insight_tenant_id, person_id, source_type, profile_id, action, reason, created_by)
VALUES
    ('example_tenant', '<person_id>', 'zoom', 'Z456', 'link', 'same_email', 'operator_name');
```

### 4. Merge two persons (move profile from P2 to P1)

```sql
-- Unlink from P2, link to P1 (one INSERT, atomic)
INSERT INTO identity.links
    (insight_tenant_id, person_id, source_type, profile_id, action, reason, created_by)
VALUES
    ('example_tenant', '<P2>', 'gitlab', 'G123', 'unlink', 'merge', 'operator_name'),
    ('example_tenant', '<P1>', 'gitlab', 'G123', 'link',   'merge', 'operator_name');
```

### 5. Split (undo merge)

```sql
INSERT INTO identity.links
    (insight_tenant_id, person_id, source_type, profile_id, action, reason, created_by)
VALUES
    ('example_tenant', '<P1>', 'gitlab', 'G123', 'unlink', 'split', 'operator_name'),
    ('example_tenant', '<P2>', 'gitlab', 'G123', 'link',   'split', 'operator_name');
```

### 6. Materialize changes

```bash
dbt run --select identity_person
```

## Cross-Domain References

- **Connectors**: Write to `staging.*__identity_input` via `identity_input_from_history` macro
- **Person domain**: `identity.identity_person` provides person field history; consumers use `argMax(field_value, valid_from)` for current state
- **Analytics**: Join fact tables with `identity.links` to resolve source profile IDs to person_id

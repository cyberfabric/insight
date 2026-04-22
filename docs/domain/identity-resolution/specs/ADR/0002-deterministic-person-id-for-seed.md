---
id: cpt-ir-adr-deterministic-person-id
status: accepted
date: 2026-04-21
---

# ADR-0002 — Deterministic `person_id` for persons initial seed

## Context

The `persons` table (MariaDB — see `cpt-insightspec-ir-dbtable-persons-mariadb`) is populated initially from ClickHouse `identity.identity_inputs` via a one-time seed script (`scripts/seed-persons-from-identity-input.py`). Each unique email within a tenant becomes one person.

During early iterations the script assigned `person_id = uuid.uuid4()` (random v4) per unique email. Re-running the script without `TRUNCATE TABLE persons` produced duplicate rows — every second run minted fresh UUIDs for the same emails — so the script had a hard idempotency guard that aborted when the table was non-empty.

This left two poor options for the operator:
- Run the script exactly once (and never again, because a re-run does nothing).
- Wipe the table with `TRUNCATE TABLE persons` to re-seed — destructive, loses any operator-authored rows, breaks any downstream foreign-key usage of `person_id`.

Neither is acceptable for a script that is supposed to be safe against accidental re-invocation.

## Decision

1. **`person_id` is deterministic**: generated as `uuid5(namespace, f"{insight_tenant_id}:{lower(trim(email))}")` with a fixed project namespace UUID (`6c7c3e2e-2f6b-5f6e-9b9d-6f8a3c2e1b4d`). The same `(tenant, email)` pair always produces the same `person_id`.

2. **`persons` has a UNIQUE constraint** on the natural key `(insight_tenant_id, person_id, insight_source_type, insight_source_id, alias_type, alias_value)` — one observation of one field for one person from one source instance is unique.

3. **Seed uses `INSERT IGNORE`** — re-runs silently skip observations that already exist and add only genuinely new ones. No abort, no `TRUNCATE`, no destruction of operator-authored rows.

4. **The script never issues `TRUNCATE`** — wiping the table remains an explicit operator action outside the script.

## Rationale

- **No data loss on re-run**: operator-authored rows and prior seed results survive. The script is safe to re-run after a new connector sync to pick up newly-observed accounts.
- **No duplicates on re-run**: the UNIQUE key enforces it at the database level; `INSERT IGNORE` handles it at the statement level. Correctness does not depend on the script being run exactly once.
- **Cross-source joining works from day one**: `person_id` is shared across all source-accounts of the same email — exactly the effect that random UUIDs would have required an additional resolution pass to achieve.
- **Compute cost is irrelevant**: `uuid5` is a trivial hash, and the seed is a one-time (or few-times) operation. The user explicitly accepted extra compute complexity in exchange for data safety.

## Consequences

- `person_id` values are **stable** across seed runs — downstream systems can reference them safely.
- The UUIDv5 namespace (`6c7c3e2e-…`) is now a project-level constant. Changing it would re-assign every `person_id` and break downstream references. Document any future change via a new ADR.
- The UNIQUE index on the observation tuple enforces the natural key. Any future column addition that should be part of the identity of an observation must update this index.
- The approach assumes `email` is the sole bootstrap key. Accounts without an email are silently skipped (same as the earlier design). This ADR does not change that.

## Alternatives considered

- **Random `person_id` + abort on non-empty table** (initial implementation). Rejected: forces destructive `TRUNCATE` to re-seed, loses operator edits.
- **Random `person_id` + lookup-by-email before insert**. Rejected: needs a round-trip per account and makes the seed O(accounts × queries); deterministic hash is O(1) per account and requires zero database lookups.
- **`person_id` as auto-increment from MariaDB**. Rejected: the column type across domains is `UUID` (glossary convention); we want `person_id` to be assignable purely in the connector side (ClickHouse) later without MariaDB round-trips.

## Related

- `cpt-insightspec-ir-dbtable-persons-mariadb` — the persons table definition
- `cpt-ir-fr-persons-initial-seed` — functional requirement for the seed
- `docs/shared/glossary/ADR/0001-uuidv7-primary-key.md` — UUID types across the project

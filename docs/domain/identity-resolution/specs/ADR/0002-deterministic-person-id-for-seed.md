---
id: cpt-ir-adr-stable-person-id
status: accepted
date: 2026-04-22
---

# ADR-0002 — Stable `person_id` via account-to-person mapping

## Context

The `persons` table (MariaDB, see
`cpt-insightspec-ir-dbtable-persons-mariadb`) is populated initially
from ClickHouse `identity.identity_inputs` via a one-time seed script
(`src/backend/services/identity/seed/seed-persons-from-identity-input.py`).

`person_id` is the join key across the whole system: everything
downstream (`aliases.person_id`, analytics joins, future Person-domain
golden record) references it. Two properties are required:

1. **Stability over time.** Once a source-account is bound to a
   `person_id`, that binding must survive changes in mutable
   attributes (email rename, domain migration, display-name change)
   and re-runs of the seed.
2. **Cross-source identity at initial bootstrap.** When the seed is
   first run against a fresh install, source-accounts that share the
   same email within a tenant must end up on one `person_id` -- that
   is the whole point of identity resolution.

A naïve "`person_id = uuid5(NAMESPACE, f'{tenant}:{email}')`" approach
satisfies (2) but breaks (1): any post-bootstrap email change would
silently shift the identifier. It also has no well-defined
post-bootstrap semantic -- re-running after a new source is enrolled
silently re-groups persons by email, bypassing the operator-driven
review that will eventually live in the UI.

This ADR records the mapping-table approach that gives us both (1)
and (2) without coupling the identifier to a mutable field, and
scopes the cross-source auto-merge to the initial-bootstrap pass only.

## Decision

1. **`person_id` is a random UUIDv7**, minted at the first observation
   of a source-account. Once minted it never changes and is never
   re-derived from any field value. UUIDv7 carries a 48-bit
   millisecond timestamp prefix so consecutive `person_id`s cluster
   in InnoDB's clustered index and secondary indexes on `person_id`
   (see glossary ADR-0001).

2. **The binding is persisted in a dedicated mapping table**,
   `account_person_map` (MariaDB, same `identity` database as
   `persons`):
   - Primary key: `(insight_tenant_id, insight_source_type,
     insight_source_id, source_account_id)`
   - Columns: `person_id` (`BINARY(16)`), `created_reason`
     (`initial-bootstrap` | `new-account` | `operator-merge`),
     `created_at` (`TIMESTAMP`).
   - Written once per account, never updated, never deleted by the
     seed script.

3. **The seed has two modes, detected at runtime from the state of
   `account_person_map`:**

   **Initial bootstrap** -- the map is empty when the seed starts.
   Source-accounts that share the same email (case- and whitespace-
   normalised) within a tenant get one `person_id` (minted once as
   UUIDv7 during the same seed pass). Every resulting mapping is
   recorded with `created_reason = 'initial-bootstrap'`.

   **Steady-state** -- the map is non-empty when the seed starts.
   - Known accounts (already in the map) reuse their mapped
     `person_id`. No re-derivation, no re-assignment.
   - Unknown accounts get a **fresh, isolated** `person_id`
     (UUIDv7). Email-equality auto-merge with existing persons is
     **disabled** in this mode. The mapping is written with
     `created_reason = 'new-account'`.

4. **Observations** (`persons` rows) are always written against the
   `person_id` that `account_person_map` supplies. Writes use
   `INSERT IGNORE` on the `uq_person_observation` UNIQUE key, so
   re-running is idempotent: identical observations are dropped on
   the statement level.

5. **The seed never issues `TRUNCATE`, `DELETE`, `UPDATE`** against
   `persons` or `account_person_map`. Wiping and re-seeding is an
   explicit operator action outside the seed.

## Rationale

- **Mutable-attribute immunity.** Nothing in a person's observable
  attributes (email, display name, platform id, employee id) feeds
  into the identifier. An email rename becomes what it semantically
  is -- a new observation with a later `created_at`, same
  `person_id`, same binding.
- **Idempotent re-run without deterministic hashing.** Stability
  comes from the mapping table (lookup), not from a hash function
  (re-derive). Operator-authored rows, merges made through future
  UIs, and prior seed output all survive.
- **Honest cross-source resolution scope.** Email-equality auto-merge
  is only applied once, at initial bootstrap, when the environment
  has no UI or operator review. Every subsequent source enrollment
  gets a fresh `person_id` per account; merging into existing
  persons is deferred to the operator flow (once UI exists).
- **Compute cost is irrelevant.** Generating random UUIDs is free.
  The seed is one-time (or few-times) infrastructure; we optimise
  for data safety, not throughput.

## Consequences

- `person_id` values are **stable** across re-runs, environment
  restores, attribute changes. Downstream references hold.
- The `account_person_map` table is now the **authoritative source
  of truth** for "which person does this source-account belong to".
  The `persons` table is derived history; the map is the binding.
- **New source enrollment does not auto-merge into existing
  persons.** The first time a previously-unseen
  `(source_type, source_id)` appears in `identity_inputs`, its
  accounts each get a distinct `person_id`, even when their emails
  coincide with emails of existing persons. This is intentional and
  matches the design from PR #182 -- once the operator UI lands,
  per-source enrollment will trigger a review / accept / reject
  flow (out of scope for this ADR).
- **Observable effect for operators**: after a new source's first
  sync, new rows in `persons` will carry fresh `person_id`s. To
  merge them into existing persons, the operator uses a separate
  flow (future work); this seed will not do it silently.
- The `created_reason` column in `account_person_map` makes audit
  trivial: every row records how its binding came into existence.
- `person_id` is no longer computable from tenant + email.
  Downstream tooling that assumed it (e.g. `uuid5(...)` lookups in
  analytics) must be rewritten to query `account_person_map` (or
  be fed the `person_id` explicitly).

## Alternatives considered

- **Deterministic `person_id = uuid5(NS, f"{tenant}:{email}")`**.
  Originally accepted, then rejected after review: ties the
  identifier to a mutable attribute; post-bootstrap email changes
  silently break every downstream reference.
- **Auto-merge by email on every seed re-run** (no map, pure
  deterministic). Rejected: turns "re-running the seed" into
  "re-groups persons whenever a new source is synced", which is the
  opposite of the operator-driven design from PR #182.
- **Auto-increment `person_id` from MariaDB**. Rejected: UUIDs are
  the glossary convention across all three domains; UUID lets the
  seed assign `person_id` offline / in a stream without a MariaDB
  round-trip per account (we still write through MariaDB today,
  but the choice keeps the door open for ClickHouse-only flows).
- **Strict "refuse to re-run if `account_person_map` not empty"**.
  Rejected as too coarse: re-running the seed after a partial
  failure is a legitimate recovery path and must not require
  operator `TRUNCATE`. The lenient rule (no merge in steady-state)
  meets the review concern without blocking operational recovery.
- **No dedicated mapping table — derive `(tenant, source_type,
  source_id, source_account) → person_id` by scanning `persons`**
  (e.g. via a dedicated `alias_type='id'` observation). Rejected
  for two reasons:
  1. **The existing observation model does not carry
     source-account identity uniformly.** Each connector emits its
     own kind of "id-like" observation -- `employee_id` in BambooHR
     is a business HR number (`CKSGP0002`, not equal to
     `source_account_id`); `platform_id` in Cursor / Claude Admin is
     the source PK (equal to `source_account_id`); `employee_id` in
     Zoom happens to coincide with `source_account_id` by
     connector-config quirk, not by design. Unifying this into one
     `alias_type='id'`-style observation would require connector-
     level changes across the ingestion layer (dbt macro +
     per-connector configs) and is outside the scope of PR #214 --
     those conventions were established upstream in PR #66.
  2. **Direct-PK lookup in a dedicated mapping table is materially
     faster** than scanning `persons` by
     `(tenant, source_type, source_id, alias_type='...', alias_value=?)`.
     Steady-state re-runs ask the mapping per-account once (O(1))
     against a tiny, binding-only table, instead of a filtered scan
     over the ever-growing observation history. The seed itself is
     infrequent, so this matters most once the map is read from
     runtime paths as well.

  The dedicated `account_person_map` is therefore kept even though
  the binding *could* in principle be reconstructed from `persons`
  alone.

## Related

- `cpt-insightspec-ir-dbtable-persons-mariadb` -- the persons table
  definition.
- `cpt-insightspec-ir-dbtable-account-person-map` -- the mapping
  table definition (same migration file).
- `cpt-ir-fr-persons-initial-seed` -- functional requirement for
  the seed.
- `docs/shared/glossary/ADR/0001-uuidv7-primary-key.md` -- UUID
  types across the project.

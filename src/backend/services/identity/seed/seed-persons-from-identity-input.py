#!/usr/bin/env python3
"""
Seed: identity.identity_inputs (ClickHouse) -> persons +
account_person_map (MariaDB).

Writes observations from `identity_inputs` into `persons`, minting
stable `person_id`s as needed, then rebuilds `account_person_map`
(an SCD2 materialized view of the source-account -> person_id
binding) from scratch.

Observation schema (persons) is split into three value columns
with hardcoded routing by `value_type`:

- value_type IN ('id', 'email', 'username')  -> persons.value_id
- value_type == 'display_name'               -> persons.value_full_text
- anything else                              -> persons.value

Exactly one of the three is populated per row; the generated
`value_effective` column makes the UNIQUE key NULL-safe.

`account_person_map` is never the source of truth. It is rebuilt
deterministically from persons rows where value_type='id' at the end
of every seed run (and will be rebuilt by future operator flows too).

Seed decision per account (single code path — no separate "initial
bootstrap" vs "steady-state" modes; the logic is the same either way
and degenerates to bootstrap when persons is empty):

1. Known account -- persons already has a value_type='id' observation
   for (tenant, source_type, source_id, source_account_id). Reuse that
   person_id. Dedupe new observations via INSERT IGNORE on the UNIQUE
   key.

2. Unknown account, email ABSENT from persons (any person_id) in this
   tenant. Mint a random UUIDv7 `person_id` and write observations.
   Within the same run, accounts sharing the same new email share one
   person_id (email-automerge is naturally scoped to the run). See
   ADR-0002.

3. Unknown account, email PRESENT in persons. SKIP the entire account.
   Linking this new source-account to an existing person is the job of
   the future identity-resolution flow (out of scope for this seed).

Prerequisites:
  - ClickHouse identity.identity_inputs view exists (run dbt first)
  - MariaDB persons / account_person_map tables exist (applied by
    the identity-resolution service's SeaORM Migrator at startup;
    see ADR-0006)
  - Environment: CLICKHOUSE_URL, CLICKHOUSE_USER, CLICKHOUSE_PASSWORD
  - Environment: MARIADB_URL (mysql://user:pass@host:port/identity)

Usage:
  # From host with port-forwards:
  export CLICKHOUSE_URL=http://localhost:30123
  export CLICKHOUSE_USER=default
  export CLICKHOUSE_PASSWORD=<from secret>
  export MARIADB_URL=mysql://insight:insight-pass@localhost:3306/identity

  python3 src/backend/services/identity/seed/seed-persons-from-identity-input.py
"""

import base64
import json
import os
import time
import urllib.parse
import urllib.request
import uuid
from collections import defaultdict
from datetime import datetime, timezone
from urllib.parse import unquote, urlparse


def uuid7() -> uuid.UUID:
    """Generate a UUIDv7 per RFC 9562: 48-bit ms timestamp + random bits.

    The time-ordered prefix clusters consecutive `person_id`s in InnoDB's
    clustered index and in the secondary indexes on `person_id`; pure
    random UUIDv4 would scatter inserts and cause page splits. See
    `docs/shared/glossary/ADR/0001-uuidv7-primary-key.md`.
    """
    ts_ms = int(time.time() * 1000)
    rand = os.urandom(10)
    b = bytearray(16)
    b[0:6] = ts_ms.to_bytes(6, "big")
    b[6] = 0x70 | (rand[0] & 0x0F)   # version 7 in high nibble
    b[7] = rand[1]
    b[8] = 0x80 | (rand[2] & 0x3F)   # variant 10xx in top 2 bits
    b[9:16] = rand[3:10]
    return uuid.UUID(bytes=bytes(b))


# MariaDB driver -- pymysql preferred, mysql.connector fallback. For
# BINARY(16) columns we pass `uuid.UUID.bytes` (16 raw bytes) rather than
# the UUID object itself: both drivers would otherwise fall back to
# str(UUID) -- a 36-char text form -- which BINARY(16) silently
# truncates to the first 16 ASCII bytes, corrupting the column.
try:
    import pymysql as _mysql_driver  # type: ignore[import-not-found]
except ImportError:
    import mysql.connector as _mysql_driver  # type: ignore[import-not-found,no-redef]


# -- Schema constraints (mirror src/backend/services/identity/src/migration/
# m20260421_000001_persons.rs -- the authoritative DDL is now in the Rust
# service's SeaORM Migrator; see ADR-0006).
# Longer values are rejected rather than silently truncated by INSERT
# IGNORE. Truncation would let two distinct source-accounts or observations
# collapse onto one key and poison the data.
MAX_VALUE_ID_LEN         = 320   # VARCHAR(320) -- RFC 5321/5322 email upper bound
MAX_VALUE_FULL_TEXT_LEN  = 512   # VARCHAR(512) -- display_name catch-all
MAX_SOURCE_ACCOUNT_ID_LEN = 320  # VARCHAR(320) -- same domain as value_id

# value_type values that hardcode-route into value_id vs value_full_text;
# everything else (employee_id, platform_id, functional_team, and any
# future custom value_type) goes into the TEXT value column.
# Canonical value_types: id, email, username, display_name. The set is
# extensible — value_type is a free-form string, not an enum.
VALUE_TYPES_FOR_VALUE_ID        = {"id", "email", "username"}
VALUE_TYPES_FOR_VALUE_FULL_TEXT = {"display_name"}

# Author sentinel for automatically-minted bindings. Real operator UUIDs
# will replace this in the future merge/split flows.
SYSTEM_AUTHOR_UUID = uuid.UUID("00000000-0000-0000-0000-000000000000")


# -- ClickHouse connection ------------------------------------------------
CH_URL      = os.environ.get("CLICKHOUSE_URL", "http://localhost:30123")
CH_USER     = os.environ.get("CLICKHOUSE_USER", "default")
CH_PASSWORD = os.environ["CLICKHOUSE_PASSWORD"]
# Hard cap on the ClickHouse HTTP query. A stalled endpoint otherwise
# hangs the whole one-shot seed indefinitely.
CH_TIMEOUT_SEC = int(os.environ.get("CLICKHOUSE_TIMEOUT_SEC", "60"))

# Guard urllib against file:// and other non-HTTP schemes -- CH_URL is read
# from env and fed to urlopen; a mistaken value should error, not open a
# local file (Bandit B310).
if urllib.parse.urlparse(CH_URL).scheme not in ("http", "https"):
    raise ValueError(
        f"CLICKHOUSE_URL must use http:// or https:// scheme; got {CH_URL!r}"
    )


def ch_query(sql: str) -> list[dict]:
    """Execute ClickHouse query, return list of dicts."""
    params = urllib.parse.urlencode({"query": sql + " FORMAT JSONEachRow"})
    url = f"{CH_URL}/?{params}"
    req = urllib.request.Request(url)
    creds = base64.b64encode(f"{CH_USER}:{CH_PASSWORD}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    with urllib.request.urlopen(req, timeout=CH_TIMEOUT_SEC) as resp:  # noqa: S310 -- scheme validated above
        lines = resp.read().decode().strip().split("\n")
        return [json.loads(line) for line in lines if line.strip()]


# -- MariaDB connection ---------------------------------------------------
def get_mariadb_conn():
    """Connect to MariaDB. Requires pymysql or mysql-connector-python."""
    mariadb_url = os.environ.get(
        "MARIADB_URL", "mysql://insight:insight-pass@localhost:3306/identity"
    )
    # seed-persons.sh URL-encodes user/password via urllib.parse.quote() so
    # that passwords containing ':', '@', '/', or '%' do not break URL
    # parsing. urlparse returns the values still-encoded -- we unquote here
    # before handing them to the driver.
    parsed = urlparse(mariadb_url)
    user = unquote(parsed.username) if parsed.username else "insight"
    password = unquote(parsed.password) if parsed.password else ""
    host = parsed.hostname or "localhost"
    port = parsed.port or 3306
    database = parsed.path.lstrip("/") or "identity"

    return _mysql_driver.connect(
        host=host, port=port, user=user, password=password,
        database=database, charset="utf8mb4", autocommit=False,
    )


# -- Value routing --------------------------------------------------------
def route_value(value_type: str, value: str) -> tuple[str | None, str | None, str | None]:
    """Return (value_id, value_full_text, value) with exactly one non-None
    per the hardcoded value_type routing rules.

    Values exceeding their column's max length are rejected by returning
    all-None, and the caller counts + logs the rejection.
    """
    if value_type in VALUE_TYPES_FOR_VALUE_ID:
        if len(value) > MAX_VALUE_ID_LEN:
            return (None, None, None)
        return (value, None, None)
    if value_type in VALUE_TYPES_FOR_VALUE_FULL_TEXT:
        if len(value) > MAX_VALUE_FULL_TEXT_LEN:
            return (None, None, None)
        return (None, value, None)
    # catch-all: TEXT column, no length limit enforced by the seed
    return (None, None, value)


# -- Main -----------------------------------------------------------------
def main():
    print("=== Seed: identity_inputs -> MariaDB persons + account_person_map ===")

    # 1. Read all identity_inputs rows from ClickHouse.
    #    ORDER BY _synced_at DESC within a source-account so that the
    #    email picked in step 3 is deterministically the latest
    #    observation -- essential for the "skip account if its current
    #    email already exists in persons" decision.
    print("  Reading identity_inputs from ClickHouse...")
    rows = ch_query("""
        SELECT
            toString(insight_tenant_id)     AS insight_tenant_id,
            toString(insight_source_id)     AS insight_source_id,
            insight_source_type,
            source_account_id,
            value_type,
            value,
            _synced_at
        FROM identity.identity_inputs
        WHERE operation_type = 'UPSERT'
          AND value IS NOT NULL
          AND value != ''
        ORDER BY
            insight_tenant_id,
            insight_source_type,
            insight_source_id,
            source_account_id,
            _synced_at DESC,
            value_type,
            value
    """)
    print(f"  Read {len(rows)} rows")

    if not rows:
        print("  No data -- nothing to seed.")
        return

    # 2. Group observations by source-account key.
    #    Key: (tenant, source_type, source_id, source_account_id) ->
    #    list of observations.
    accounts: dict[tuple, list[dict]] = defaultdict(list)
    for r in rows:
        key = (
            r["insight_tenant_id"],
            r["insight_source_type"],
            r["insight_source_id"],
            r["source_account_id"],
        )
        accounts[key].append(r)

    print("  Connecting to MariaDB...")
    conn = get_mariadb_conn()
    cursor = conn.cursor()

    # 3. Load existing source_account -> person_id bindings from persons
    #    (value_type='id' is the authoritative binding observation per
    #    ADR-0002). Derive "latest person_id per account" in SQL -- this
    #    becomes our known-account lookup set.
    cursor.execute(
        """
        SELECT insight_tenant_id, insight_source_type, insight_source_id,
               value_id AS source_account_id, person_id
        FROM persons p
        WHERE value_type = 'id'
          AND value_id IS NOT NULL
          AND created_at = (
              SELECT MAX(p2.created_at) FROM persons p2
              WHERE p2.insight_tenant_id   = p.insight_tenant_id
                AND p2.insight_source_type = p.insight_source_type
                AND p2.insight_source_id   = p.insight_source_id
                AND p2.value_id            = p.value_id
                AND p2.value_type          = 'id'
          )
        """
    )
    known_accounts: dict[tuple[str, str, str, str], uuid.UUID] = {}
    for tenant_bytes, source_type, source_id_bytes, src_account, person_bytes in cursor.fetchall():
        key = (
            str(uuid.UUID(bytes=tenant_bytes)),
            source_type,
            str(uuid.UUID(bytes=source_id_bytes)),
            src_account,
        )
        known_accounts[key] = uuid.UUID(bytes=person_bytes)

    # 4. Load existing (tenant, normalized_email) set from persons.
    #    An email present here blocks creating a new person for any
    #    unknown account carrying that email -- that is work for the
    #    identity-resolution flow (future PR). We normalize in SQL via
    #    LOWER(TRIM()) so the set can be compared directly with
    #    lower(trim(email)) from identity_inputs.
    cursor.execute(
        """
        SELECT insight_tenant_id, LOWER(TRIM(value_id)) AS email
        FROM persons
        WHERE value_type = 'email'
          AND value_id IS NOT NULL
          AND value_id != ''
        """
    )
    existing_emails: set[tuple[str, str]] = set()
    for tenant_bytes, email_norm in cursor.fetchall():
        tenant_str = str(uuid.UUID(bytes=tenant_bytes))
        existing_emails.add((tenant_str, email_norm))

    print(
        f"  persons state: {len(known_accounts)} known bindings, "
        f"{len(existing_emails)} existing emails"
    )

    # 5. Assign person_id per source-account. Single code path:
    #    - Known accounts reuse the mapped person_id (stable).
    #    - Unknown accounts whose email is absent from persons get a
    #      new UUIDv7; within this run, two new accounts sharing a new
    #      email share one person_id (email-automerge within the run).
    #    - Unknown accounts whose email is already present in persons
    #      are skipped entirely -- cross-source linking is operator-
    #      driven work for the future identity-resolution flow.
    #
    #    Accounts without an email observation are skipped -- email is
    #    the sole identity anchor for this seed.
    email_to_new_person: dict[tuple[str, str], uuid.UUID] = {}
    account_person: dict[tuple, uuid.UUID] = {}

    reused_from_persons       = 0
    minted                    = 0
    skipped_no_email          = 0
    skipped_email_exists      = 0
    skipped_oversized_account = 0

    for key, obs_list in accounts.items():
        if key in known_accounts:
            account_person[key] = known_accounts[key]
            reused_from_persons += 1
            continue

        tenant_id, source_type, source_id_str, source_account_id = key

        if len(source_account_id) > MAX_SOURCE_ACCOUNT_ID_LEN:
            skipped_oversized_account += 1
            continue

        # Pick the latest email observation for this account. Rows are
        # ordered by _synced_at DESC (see step 1), so the first email
        # in obs_list is the most recent.
        email_raw: str | None = None
        for obs in obs_list:
            if obs["value_type"] == "email":
                email_raw = obs["value"]
                break
        if not email_raw:
            skipped_no_email += 1
            continue

        email_normalized = email_raw.strip().lower()
        email_key = (tenant_id, email_normalized)

        if email_key in existing_emails:
            # IRes-territory: this email is already bound to a person
            # in persons. Deciding whether to link this new account to
            # that person (same user? different user same email?) is
            # operator-driven work deferred to the future flow.
            skipped_email_exists += 1
            continue

        # Email is new in persons. Mint (or reuse from this run's
        # email-automerge set for intra-run duplicates).
        person_uuid = email_to_new_person.get(email_key)
        if person_uuid is None:
            person_uuid = uuid7()
            email_to_new_person[email_key] = person_uuid
            minted += 1

        account_person[key] = person_uuid

    print(
        f"  Accounts: reused={reused_from_persons}, minted={minted}, "
        f"skipped-no-email={skipped_no_email}, "
        f"skipped-email-exists={skipped_email_exists}"
    )
    if skipped_oversized_account:
        print(f"  Accounts skipped -- source_account_id > {MAX_SOURCE_ACCOUNT_ID_LEN} characters: {skipped_oversized_account}")

    # 6. Build INSERT rows for persons observations.
    #    Hardcoded routing per value_type populates exactly one of
    #    (value_id, value_full_text, value); the other two are NULL.
    #    For value_type='id' we also normalize the value from the
    #    identity_inputs source_account_id carried on the observation.
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.000")
    insert_rows = []
    oversized_value_id        = 0
    oversized_value_full_text = 0

    for key, obs_list in accounts.items():
        person_id = account_person.get(key)
        if person_id is None:
            continue  # skipped earlier
        tenant_str, source_type, source_id_str, _ = key
        # tenant_id and insight_source_id come from identity.identity_inputs,
        # where ClickHouse types both columns as UUID -- toString() on the
        # wire always yields a valid UUID string. An invalid value here is
        # an ingestion-pipeline bug; fail loudly with uuid.UUID's native
        # ValueError rather than silently dropping the observation.
        # Bind as 16-byte raw (UUID.bytes) so BINARY(16) gets the real
        # binary value, not the 36-char text form truncated to 16 ASCII
        # bytes.
        tenant_bin = uuid.UUID(tenant_str).bytes
        source_bin = uuid.UUID(source_id_str).bytes
        person_bin = person_id.bytes
        author_bin = SYSTEM_AUTHOR_UUID.bytes  # seed-minted -> system sentinel

        for obs in obs_list:
            v_id, v_ft, v_any = route_value(obs["value_type"], obs["value"])
            if v_id is None and v_ft is None and v_any is None:
                # Oversized -- route_value already discarded it; count
                # by which column would have received it.
                if obs["value_type"] in VALUE_TYPES_FOR_VALUE_ID:
                    oversized_value_id += 1
                elif obs["value_type"] in VALUE_TYPES_FOR_VALUE_FULL_TEXT:
                    oversized_value_full_text += 1
                continue
            insert_rows.append((
                obs["value_type"],
                source_type,
                source_bin,
                tenant_bin,
                v_id,
                v_ft,
                v_any,
                person_bin,
                author_bin,
                "",     # reason
                now,
            ))

    print(f"  Rows to insert (pre-dedup): {len(insert_rows)}")
    if oversized_value_id:
        print(f"  Observations skipped -- value_id > {MAX_VALUE_ID_LEN} characters: {oversized_value_id}")
    if oversized_value_full_text:
        print(f"  Observations skipped -- value_full_text > {MAX_VALUE_FULL_TEXT_LEN} characters: {oversized_value_full_text}")

    # 7. Write observations to persons via INSERT IGNORE. The
    #    uq_person_observation UNIQUE KEY (on value_effective) skips
    #    identical observations -- re-running is idempotent. No TRUNCATE
    #    anywhere; to wipe and re-seed, an operator does it manually
    #    outside this script.
    cursor.execute("SELECT COUNT(*) FROM persons")
    existing_before = cursor.fetchone()[0]
    print(f"  Existing persons rows before seed: {existing_before}")

    if insert_rows:
        print(f"  Upserting {len(insert_rows)} persons rows (INSERT IGNORE)...")
        cursor.executemany(
            """INSERT IGNORE INTO persons
               (value_type, insight_source_type, insight_source_id, insight_tenant_id,
                value_id, value_full_text, value,
                person_id, author_person_id, reason, created_at)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
            insert_rows,
        )
    conn.commit()

    cursor.execute("SELECT COUNT(*) FROM persons")
    existing_after = cursor.fetchone()[0]
    added = existing_after - existing_before
    skipped_dups = len(insert_rows) - added
    print(f"  Added: {added}, skipped as duplicates: {skipped_dups}, total: {existing_after}")

    # 8. Rebuild account_person_map from persons (SCD2).
    #    The map is never the source of truth -- persons is. Every
    #    value_type='id' observation becomes a binding row with
    #    valid_from = its created_at; valid_to = LEAD(created_at) over
    #    the same account (NULL for the latest binding). Truncate +
    #    re-INSERT in one transaction eliminates drift by construction.
    print("  Rebuilding account_person_map from persons (value_type='id')...")
    cursor.execute("TRUNCATE TABLE account_person_map")
    cursor.execute(
        """
        INSERT INTO account_person_map
            (insight_tenant_id, insight_source_type, insight_source_id, source_account_id,
             person_id, author_person_id, reason, valid_from, valid_to)
        SELECT
            insight_tenant_id,
            insight_source_type,
            insight_source_id,
            value_id                                      AS source_account_id,
            person_id,
            author_person_id,
            reason,
            created_at                                    AS valid_from,
            LEAD(created_at) OVER (
                PARTITION BY insight_tenant_id, insight_source_type,
                             insight_source_id, value_id
                ORDER BY created_at
            )                                             AS valid_to
        FROM persons
        WHERE value_type = 'id' AND value_id IS NOT NULL
        """
    )
    conn.commit()

    # Summary
    cursor.execute("""
        SELECT value_type, COUNT(*) AS cnt
        FROM persons
        GROUP BY value_type
        ORDER BY value_type
    """)
    print("\n  persons by value_type:")
    for row in cursor.fetchall():
        print(f"    {row[0]}: {row[1]}")

    cursor.execute("SELECT COUNT(DISTINCT person_id) FROM persons")
    print(f"    unique persons: {cursor.fetchone()[0]}")
    cursor.execute("SELECT COUNT(*) FROM account_person_map")
    total_map = cursor.fetchone()[0]
    cursor.execute("SELECT COUNT(*) FROM account_person_map WHERE valid_to IS NULL")
    current_map = cursor.fetchone()[0]
    print(f"    account_person_map rows: {total_map} ({current_map} current, {total_map - current_map} historical)")

    conn.close()
    print("\n=== Seed complete ===")


if __name__ == "__main__":
    main()

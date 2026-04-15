-- ============================================================
-- ⚠ AD-HOC TESTING ONLY — NOT KEPT IN SYNC WITH DBT MODELS ⚠
-- ============================================================
-- Manual SQL for testing in ClickHouse Play UI.
-- These are point-in-time snapshots of the dbt model logic.
-- Canonical source of truth: src/ingestion/dbt/identity/seed_*.sql
-- If dbt models change, these files may produce different results.
--
-- http://localhost:30123/play  (user: default, password: clickhouse_local)
-- http://localhost:8123/play
--
-- Run each statement separately (copy one block at a time).
-- Raw SQL equivalents of dbt models:
--   seed_persons_from_cursor.sql
--   seed_aliases_from_cursor.sql
--   seed_bootstrap_inputs_from_cursor.sql
-- ============================================================


-- TEMPORARY: insight_tenant_id derived via sipHash128 until tenants table exists.

-- ============================================================
-- Step 1: Add persons from Cursor (skip existing by email)
-- ============================================================

INSERT INTO person.persons (
    id, insight_tenant_id, display_name, display_name_source,
    status, email, email_source, role, role_source, completeness_score
)
SELECT
    generateUUIDv7(),
    toUUID(UUIDNumToString(sipHash128(coalesce(tenant_id, '')))),
    coalesce(name, ''),
    'cursor',
    CASE WHEN isRemoved = true THEN 'inactive' ELSE 'active' END,
    lower(trim(coalesce(email, ''))),
    'cursor',
    coalesce(role, ''),
    'cursor',
    -- completeness = non-empty golden attrs / 7 (display_name,email,username,role,manager,org_unit,location)
    (if(name IS NOT NULL AND name != '', 1, 0)
     + if(email IS NOT NULL AND email != '', 1, 0)
     + if(role IS NOT NULL AND role != '', 1, 0)) / 7.0
FROM bronze_cursor.cursor_members cm
WHERE cm.email IS NOT NULL AND cm.email != ''
QUALIFY row_number() OVER (PARTITION BY lower(trim(email)), coalesce(tenant_id, '') ORDER BY _airbyte_extracted_at DESC) = 1
  AND NOT EXISTS (
      SELECT 1 FROM person.persons ex
      WHERE lower(ex.email) = lower(trim(cm.email))
        AND ex.insight_tenant_id = toUUID(UUIDNumToString(sipHash128(coalesce(cm.tenant_id, ''))))
        AND ex.is_deleted = 0
  );


-- ============================================================
-- Step 2: Add aliases from Cursor (skip existing)
-- ============================================================

INSERT INTO identity.aliases (
    id, insight_tenant_id, person_id, alias_type, alias_value,
    alias_field_name, insight_source_type, source_account_id
)
WITH source AS (
    SELECT
        cm.id           AS source_account_id,
        cm.name,
        cm.email,
        p.id            AS person_id,
        p.insight_tenant_id
    FROM bronze_cursor.cursor_members cm
    INNER JOIN person.persons p ON lower(trim(cm.email)) = lower(p.email)
        AND toUUID(UUIDNumToString(sipHash128(coalesce(cm.tenant_id, '')))) = p.insight_tenant_id  -- TEMPORARY: until tenants table
    WHERE cm.email IS NOT NULL AND cm.email != ''
),
new_aliases AS (
    SELECT person_id, insight_tenant_id, source_account_id,
           'email' AS alias_type,
           lower(trim(email)) AS alias_value,
           'bronze_cursor.cursor_members.email' AS alias_field_name
    FROM source WHERE email IS NOT NULL AND email != ''
    UNION ALL
    SELECT person_id, insight_tenant_id, source_account_id,
           'platform_id',
           trim(source_account_id),
           'bronze_cursor.cursor_members.id'
    FROM source WHERE source_account_id IS NOT NULL AND source_account_id != ''
    UNION ALL
    SELECT person_id, insight_tenant_id, source_account_id,
           'display_name',
           trim(name),
           'bronze_cursor.cursor_members.name'
    FROM source WHERE name IS NOT NULL AND name != ''
)
SELECT
    generateUUIDv7(),
    na.insight_tenant_id,
    na.person_id,
    na.alias_type,
    na.alias_value,
    na.alias_field_name,
    'cursor',
    na.source_account_id
FROM new_aliases na
LEFT ANTI JOIN identity.aliases existing
    ON  na.alias_type              = existing.alias_type
    AND na.alias_value             = existing.alias_value
    AND na.source_account_id       = existing.source_account_id
    AND existing.insight_source_type = 'cursor'
    AND existing.is_deleted        = 0;


-- ============================================================
-- Step 3: Add bootstrap_inputs from Cursor (raw observations)
-- ============================================================

INSERT INTO identity.bootstrap_inputs (
    id, insight_tenant_id, insight_source_type, source_account_id,
    alias_type, alias_value, alias_field_name, operation_type
)
WITH source AS (
    SELECT
        cm.id           AS source_account_id,
        cm.name,
        cm.email,
        cm.tenant_id
    FROM bronze_cursor.cursor_members cm
    WHERE cm.email IS NOT NULL AND cm.email != ''
),
observations AS (
    SELECT source_account_id, tenant_id,
           'email' AS alias_type,
           email AS alias_value,
           'bronze_cursor.cursor_members.email' AS alias_field_name
    FROM source WHERE email IS NOT NULL AND email != ''
    UNION ALL
    SELECT source_account_id, tenant_id,
           'platform_id',
           source_account_id,
           'bronze_cursor.cursor_members.id'
    FROM source WHERE source_account_id IS NOT NULL AND source_account_id != ''
    UNION ALL
    SELECT source_account_id, tenant_id,
           'display_name',
           name,
           'bronze_cursor.cursor_members.name'
    FROM source WHERE name IS NOT NULL AND name != ''
)
SELECT
    generateUUIDv7(),
    toUUID(UUIDNumToString(sipHash128(coalesce(o.tenant_id, '')))),
    'cursor',
    o.source_account_id,
    o.alias_type,
    o.alias_value,
    o.alias_field_name,
    'UPSERT'
FROM observations o
LEFT ANTI JOIN identity.bootstrap_inputs existing
    ON  o.alias_type              = existing.alias_type
    AND o.alias_value             = existing.alias_value
    AND o.source_account_id       = existing.source_account_id
    AND existing.insight_source_type = 'cursor';


-- ============================================================
-- Verify
-- ============================================================

-- SELECT count() FROM person.persons;
-- SELECT insight_tenant_id, count() FROM person.persons GROUP BY insight_tenant_id;
-- SELECT alias_type, count() FROM identity.aliases GROUP BY alias_type;
-- SELECT insight_source_type, alias_type, count() FROM identity.bootstrap_inputs GROUP BY insight_source_type, alias_type;

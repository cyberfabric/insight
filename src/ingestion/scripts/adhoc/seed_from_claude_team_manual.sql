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
--   seed_persons_from_claude_team.sql
--   seed_aliases_from_claude_team.sql
--   seed_bootstrap_inputs_from_claude_team.sql
-- ============================================================

-- TEMPORARY: insight_tenant_id derived via sipHash128 until tenants table exists.

-- ============================================================
-- Step 1: Add persons from Claude Team (skip existing by email)
-- ============================================================

INSERT INTO person.persons (
    id, insight_tenant_id, display_name, display_name_source,
    status, email, email_source, role, role_source, completeness_score
)
WITH latest AS (
    SELECT email, name, role, type, tenant_id
    FROM bronze_claude_team.claude_team_users
    WHERE email IS NOT NULL AND email != ''
    QUALIFY row_number() OVER (PARTITION BY lower(trim(email)), coalesce(tenant_id, '') ORDER BY _airbyte_extracted_at DESC) = 1
)
SELECT
    generateUUIDv7(),
    toUUID(UUIDNumToString(sipHash128(coalesce(tenant_id, '')))),
    coalesce(name, ''),
    'claude_team',
    'active',
    lower(trim(email)),
    'claude_team',
    coalesce(role, ''),
    'claude_team',
    -- completeness = non-empty golden attrs / 7 (display_name,email,username,role,manager,org_unit,location)
    (if(name IS NOT NULL AND name != '', 1, 0)
     + if(email != '', 1, 0)
     + if(role IS NOT NULL AND role != '', 1, 0)) / 7.0
FROM latest l
LEFT ANTI JOIN person.persons ex
    ON lower(trim(l.email)) = lower(ex.email)
    AND toUUID(UUIDNumToString(sipHash128(coalesce(l.tenant_id, '')))) = ex.insight_tenant_id  -- TEMPORARY: until tenants table
    AND ex.is_deleted = 0;


-- ============================================================
-- Step 2: Add aliases from Claude Team (skip existing)
-- ============================================================

INSERT INTO identity.aliases (
    id, insight_tenant_id, person_id, alias_type, alias_value,
    alias_field_name, insight_source_type, source_account_id
)
WITH latest AS (
    SELECT id AS source_id, email, name, tenant_id
    FROM bronze_claude_team.claude_team_users
    WHERE email IS NOT NULL AND email != ''
    QUALIFY row_number() OVER (PARTITION BY lower(trim(email)), coalesce(tenant_id, '') ORDER BY _airbyte_extracted_at DESC) = 1
),
source AS (
    SELECT
        l.source_id     AS source_account_id,
        l.name,
        l.email,
        p.id            AS person_id,
        p.insight_tenant_id
    FROM latest l
    INNER JOIN person.persons p ON lower(trim(l.email)) = lower(p.email)
        AND toUUID(UUIDNumToString(sipHash128(coalesce(l.tenant_id, '')))) = p.insight_tenant_id  -- TEMPORARY: until tenants table
),
new_aliases AS (
    SELECT person_id, insight_tenant_id, source_account_id,
           'email' AS alias_type,
           lower(trim(email)) AS alias_value,
           'bronze_claude_team.claude_team_users.email' AS alias_field_name
    FROM source WHERE email IS NOT NULL AND email != ''
    UNION ALL
    SELECT person_id, insight_tenant_id, source_account_id,
           'platform_id',
           trim(source_account_id),
           'bronze_claude_team.claude_team_users.id'
    FROM source WHERE source_account_id IS NOT NULL AND source_account_id != ''
    UNION ALL
    SELECT person_id, insight_tenant_id, source_account_id,
           'display_name',
           trim(name),
           'bronze_claude_team.claude_team_users.name'
    FROM source WHERE name IS NOT NULL AND name != ''
)
SELECT
    generateUUIDv7(),
    na.insight_tenant_id,
    na.person_id,
    na.alias_type,
    na.alias_value,
    na.alias_field_name,
    'claude_team',
    na.source_account_id
FROM new_aliases na
LEFT ANTI JOIN identity.aliases existing
    ON  na.alias_type              = existing.alias_type
    AND na.alias_value             = existing.alias_value
    AND na.source_account_id       = existing.source_account_id
    AND existing.insight_source_type = 'claude_team'
    AND existing.is_deleted        = 0;


-- ============================================================
-- Step 3: Add bootstrap_inputs from Claude Team (raw observations)
-- ============================================================

INSERT INTO identity.bootstrap_inputs (
    id, insight_tenant_id, insight_source_type, source_account_id,
    alias_type, alias_value, alias_field_name, operation_type
)
WITH latest AS (
    SELECT id AS source_id, email, name, tenant_id
    FROM bronze_claude_team.claude_team_users
    WHERE email IS NOT NULL AND email != ''
    QUALIFY row_number() OVER (PARTITION BY lower(trim(email)), coalesce(tenant_id, '') ORDER BY _airbyte_extracted_at DESC) = 1
),
observations AS (
    SELECT source_id AS source_account_id, tenant_id,
           'email' AS alias_type,
           email AS alias_value,
           'bronze_claude_team.claude_team_users.email' AS alias_field_name
    FROM latest WHERE email IS NOT NULL AND email != ''
    UNION ALL
    SELECT source_id, tenant_id,
           'platform_id',
           source_id,
           'bronze_claude_team.claude_team_users.id'
    FROM latest WHERE source_id IS NOT NULL AND source_id != ''
    UNION ALL
    SELECT source_id, tenant_id,
           'display_name',
           name,
           'bronze_claude_team.claude_team_users.name'
    FROM latest WHERE name IS NOT NULL AND name != ''
)
SELECT
    generateUUIDv7(),
    toUUID(UUIDNumToString(sipHash128(coalesce(o.tenant_id, '')))),
    'claude_team',
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
    AND existing.insight_source_type = 'claude_team';


-- ============================================================
-- Verify results
-- ============================================================

-- Check new persons added
-- SELECT count() FROM person.persons;

-- Check aliases by source
-- SELECT insight_source_type, alias_type, count() FROM identity.aliases GROUP BY insight_source_type, alias_type ORDER BY insight_source_type, alias_type;

-- Check bootstrap_inputs by source
-- SELECT insight_source_type, alias_type, count() FROM identity.bootstrap_inputs GROUP BY insight_source_type, alias_type ORDER BY insight_source_type, alias_type;

-- Check a specific person's aliases across sources
-- SELECT p.display_name, a.alias_type, a.alias_value, a.insight_source_type, a.alias_field_name
-- FROM person.persons p
-- INNER JOIN identity.aliases a ON p.id = a.person_id
-- WHERE p.display_name = 'Ivan Lukianov'
-- ORDER BY a.insight_source_type, a.alias_type;

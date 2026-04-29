-- Bronze → Silver step 1: Confluence page versions → class_wiki_activity
--
-- Per-user per-day edit activity rolled up from wiki_page_versions. One row
-- per (tenant, source, author, day) with counts of pages edited, total edits,
-- pages created (version_number = 1), major edits, minor edits.
--
-- Identity resolution: same pattern as confluence__wiki_pages — LEFT JOIN
-- with bronze_jira.jira_user on accountId. Skipped at compile-time if Jira
-- is not provisioned; author_email falls back to NULL.
--
-- Scaling note: materialized as view, which recomputes the versions → agg
-- pipeline on every downstream query. Fine for MVP (tens of thousands of
-- versions). Promote to materialized='incremental' keyed on (author_id, day)
-- once wiki_page_versions grows past ~1M rows or Gold query latency rises.
{{ config(
    materialized='view',
    schema='staging',
    tags=['confluence', 'silver:class_wiki_activity']
) }}

{%- set jira_user = adapter.get_relation(database=none, schema='bronze_jira', identifier='jira_user') -%}

WITH versions AS (
    SELECT
        tenant_id,
        source_id,
        page_id,
        author_id,
        toUInt32(coalesce(version_number, 0))                               AS version_number,
        coalesce(minor_edit, false)                                         AS minor_edit,
        toDate(parseDateTime64BestEffortOrNull(coalesce(created_at, ''), 3)) AS day,
        parseDateTime64BestEffortOrNull(coalesce(collected_at, ''), 3)      AS collected_at
    FROM {{ source('bronze_confluence', 'wiki_page_versions') }}
    WHERE author_id IS NOT NULL AND author_id != ''
    QUALIFY row_number() OVER (PARTITION BY unique_key ORDER BY _airbyte_extracted_at DESC) = 1
),

agg AS (
    SELECT
        tenant_id,
        source_id,
        author_id,
        day,
        -- uniqExact (not uniq): uniq is HyperLogLog and can miscount by a
        -- full unit for small per-day page counts, directly skewing the
        -- pages_edited metric. uniqExact is correct at this scale.
        uniqExact(page_id)                                                  AS pages_edited,
        count()                                                             AS total_edits,
        countIf(version_number = 1)                                         AS pages_created,
        countIf(not minor_edit)                                             AS major_edits,
        countIf(minor_edit)                                                 AS minor_edits,
        max(collected_at)                                                   AS collected_at_max
    FROM versions
    WHERE day IS NOT NULL
    GROUP BY tenant_id, source_id, author_id, day
)

{%- if jira_user %}
, users AS (
    SELECT
        tenant_id,
        account_id,
        lower(trim(email))                                                  AS email
    FROM {{ source('bronze_jira', 'jira_user') }}
    WHERE email IS NOT NULL AND trim(email) != ''
    QUALIFY row_number() OVER (PARTITION BY tenant_id, account_id ORDER BY _airbyte_extracted_at DESC) = 1
)
{%- endif %}

SELECT
    a.tenant_id,
    a.source_id,
    CAST(concat(
        coalesce(a.tenant_id, ''), '-',
        coalesce(a.source_id, ''), '-',
        a.author_id, '-',
        toString(a.day)
    ) AS String)                                                            AS unique_key,
    a.author_id,
    {% if jira_user %}u.email{% else %}CAST(NULL AS Nullable(String)){% endif %}                                                     AS author_email,
    a.day,
    toUInt32(a.pages_edited)                                                AS pages_edited,
    toUInt32(a.total_edits)                                                 AS total_edits,
    toUInt32(a.pages_created)                                               AS pages_created,
    toUInt32(a.major_edits)                                                 AS major_edits,
    toUInt32(a.minor_edits)                                                 AS minor_edits,
    'confluence'                                                            AS source,
    'insight_confluence'                                                    AS data_source,
    CAST(a.collected_at_max AS Nullable(DateTime64(3)))                     AS collected_at
FROM agg a
{%- if jira_user %}
LEFT JOIN users u
    ON a.tenant_id = u.tenant_id
   AND a.author_id = u.account_id
{%- endif %}

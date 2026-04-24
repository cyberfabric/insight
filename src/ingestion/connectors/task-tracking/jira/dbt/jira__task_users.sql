{{ config(
    materialized='incremental',
    alias='jira__task_users',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(insight_source_id, data_source, user_id)',
    settings={'allow_nullable_key': 1},
    tags=['jira', 'silver:class_task_users']
) }}

-- Per-source staging model; unioned into `silver.class_task_users` via `union_by_tag`.
-- Anchor for identity resolution.
--
-- `_version` is `_airbyte_extracted_at` — deterministic and monotonic. Using `now64(3)`
-- here would make replacement order within a single run indeterminate (rows get
-- slightly different timestamps).

SELECT
    u.source_id                                 AS insight_source_id,
    CAST('jira' AS String)                      AS data_source,
    u.account_id                                AS user_id,
    u.email                                     AS email,
    u.display_name                              AS display_name,
    CAST(NULL AS Nullable(String))              AS username,
    u.account_type                              AS account_type,
    -- Same reason as `archived` in jira__task_projects: `u.active` is `Nullable(Bool)`;
    -- `toUInt8OrNull(toString(...))` was silently producing 100% NULL.
    CAST(u.active AS Nullable(UInt8))           AS is_active,
    toDateTime64(u._airbyte_extracted_at, 3)    AS collected_at,
    toUnixTimestamp64Milli(u._airbyte_extracted_at) AS _version
FROM {{ source('bronze_jira', 'jira_user') }} u
-- `jira_user` bronze = MergeTree (full_refresh + overwrite), FINAL not supported and not needed.

{{ config(
    materialized='incremental',
    alias='jira__task_sprints',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(insight_source_id, data_source, sprint_id)',
    settings={'allow_nullable_key': 1},
    tags=['jira', 'silver:class_task_sprints']
) }}

-- Bronze `jira_sprints` doesn't carry `board_name` or `project_key` (Phase 1 SubstreamPartitionRouter
-- limitation per jira/jira.md). Left NULL here.

SELECT
    s.source_id                                 AS insight_source_id,
    CAST('jira' AS String)                      AS data_source,
    toString(s.sprint_id)                       AS sprint_id,
    toString(s.board_id)                        AS board_id,
    CAST(NULL AS Nullable(String))              AS board_name,
    s.sprint_name                               AS sprint_name,
    CAST(NULL AS Nullable(String))              AS project_key,
    s.state                                     AS state,
    parseDateTime64BestEffortOrNull(s.start_date, 3)     AS start_date,
    parseDateTime64BestEffortOrNull(s.end_date, 3)       AS end_date,
    parseDateTime64BestEffortOrNull(s.complete_date, 3)  AS complete_date,
    now64(3)                                    AS collected_at,
    toUnixTimestamp64Milli(now64(3))            AS _version
FROM {{ source('bronze_jira', 'jira_sprints') }} s
-- `jira_sprints` bronze = MergeTree (full_refresh + overwrite), FINAL not supported and not needed.

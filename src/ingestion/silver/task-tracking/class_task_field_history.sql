-- depends_on: {{ ref('jira__task_field_history') }}
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='silver',
    engine='ReplacingMergeTree(_version)',
    order_by='(insight_source_id, data_source, id_readable, field_id, event_id)',
    settings={'allow_nullable_key': 1},
    tags=['silver']
) }}

-- `field_id` MUST be in the ORDER BY. Per ADR-005, synthetic_initial rows share the
-- same `event_id` (`initial:<issue_id>`) across fields of one issue, and real-change
-- rows share `event_id = changelog_id` across fields of one changelog — without
-- `field_id` in the replacement key, N per-field rows collapse to one.

-- Event-sourced per-(issue × field × event) history. Source of truth is the Rust
-- `jira-enrich` binary, which writes `staging.jira__task_field_history` — see
-- `jira__task_field_history.sql` for the thin view that exposes it here.

SELECT * FROM (
    {{ union_by_tag('silver:class_task_field_history') }}
)
{% if is_incremental() %}
WHERE _version > (SELECT max(_version) FROM {{ this }})
{% endif %}

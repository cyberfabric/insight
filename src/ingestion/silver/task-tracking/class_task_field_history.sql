-- depends_on: {{ ref('jira__task_field_history') }}
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='silver',
    engine='ReplacingMergeTree(_version)',
    order_by='(insight_source_id, data_source, id_readable, event_id)',
    settings={'allow_nullable_key': 1},
    tags=['silver']
) }}

-- Event-sourced per-(issue × field × event) history. Source of truth is the Rust
-- `jira-enrich` binary, which writes `staging.jira__task_field_history` — see
-- `jira__task_field_history.sql` for the thin view that exposes it here.

SELECT * FROM (
    {{ union_by_tag('silver:class_task_field_history') }}
)
{% if is_incremental() %}
WHERE _version > (SELECT max(_version) FROM {{ this }})
{% endif %}

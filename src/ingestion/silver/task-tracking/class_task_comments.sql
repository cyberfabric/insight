-- depends_on: {{ ref('jira__task_comments') }}
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='silver',
    engine='ReplacingMergeTree(_version)',
    order_by='(insight_source_id, data_source, comment_id)',
    settings={'allow_nullable_key': 1},
    tags=['silver']
) }}

SELECT * FROM (
    {{ union_by_tag('silver:class_task_comments') }}
)
{% if is_incremental() %}
WHERE _version > (SELECT max(_version) FROM {{ this }})
{% endif %}

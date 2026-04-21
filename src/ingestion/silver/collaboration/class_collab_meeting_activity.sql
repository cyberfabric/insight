{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

-- explicit dependency so dbt knows to run staging models first
-- depends_on: {{ ref('m365__collab_meeting_activity') }}
-- depends_on: {{ ref('zoom__collab_meeting_activity') }}

{{ union_by_tag('silver:class_collab_meeting_activity') }}

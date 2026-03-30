{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

-- explicit dependency so dbt knows to run staging models first
-- depends_on: {{ ref('m365__comms_events') }}
-- depends_on: {{ ref('zoom__comms_events') }}

{{ union_by_tag('silver:class_comms_events') }}
